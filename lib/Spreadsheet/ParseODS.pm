package Spreadsheet::ParseODS;
use strict;
use warnings;

use Archive::Zip ':ERROR_CODES';
use Moo 2;
use XML::Parser;
use XML::Twig::XPath;
use Carp qw(croak);
use List::Util 'max';
#use Storable 'dclone';

our $VERSION = '0.25'; # XXX for testing Spreadsheet::Read
our @CARP_NOT = (qw(XML::Twig));

use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';
use PerlX::Maybe;

use Spreadsheet::ParseODS::Workbook;
use Spreadsheet::ParseODS::Worksheet;
use Spreadsheet::ParseODS::Cell;
use Spreadsheet::ParseODS::Styles;
use Spreadsheet::ParseODS::Settings;

=head1 NAME

Spreadsheet::ParseODS - read SXC and ODS files

=head1 SYNOPSIS

  my $parser = Spreadsheet::ParseODS->new(
      line_separator => "\n", # for multiline values
  );
  my $workbook = $parser->parse("$d/$file");
  my $sheet = $workbook->worksheet('Sheet1');

=head1 WARNING

This module is not yet API-compatible with Spreadsheet::ParseXLSX
and Spreadsheet::ParseXLS. Method-level compatibility is planned, but there
always be differences in the values returned, for example for the cell
types.

=head1 METHODS

=head2 C<< ->new >>

=head3 Options

=over 4

=item *

B<line_separator> - the value to separate multi-line cell values with

=cut

has 'line_separator'       => ( is => 'ro', default => "\n", );

=item *

B<readonly> - create the sheet as readonly, sharing Cells between repeated
rows. This uses less memory at the cost of not being able to modify the data
structure.

=cut

has 'readonly'             => ( is => 'rw' );

=item *

B<NoTruncate> - legacy option not to truncate the sheets by stripping
empty columns from the right edge of a sheet. This option will likely be
renamed or moved.

=cut

has 'NoTruncate'           => ( is => 'ro', default => 0,  );

=item *

B<twig> - a premade L<XML::Twig::XPath> instance

=cut

has 'twig' => (
    is => 'lazy',
    default => sub {
        XML::Twig::XPath->new(
            no_xxe => 1,
            keep_spaces => 1,
        )
    },
);

=back

=cut

# -----------------------------------------------------------------------------
# col2int (for Spreadsheet::ParseExcel::Utility)
#------------------------------------------------------------------------------
# converts a excel row letter into an int for use in an array
sub col2int {
    my $result = 0;
    my $str    = shift;
    my $incr   = 1;

    for ( my $i = length($str) ; $i > 0 ; $i-- ) {
        my $char = substr( $str, $i - 1 );
        my $curr += ord( lc($char) ) - ord('a') + 1;
        $curr *= $incr;
        $result += $curr;
        $incr   *= 26;
    }

    # this is one out as we range 0..x-1 not 1..x
    $result--;

    return $result;
}

# -----------------------------------------------------------------------------
# sheetRef (for Spreadsheet::ParseExcel::Utility)
#------------------------------------------------------------------------------
# -----------------------------------------------------------------------------
### sheetRef
# convert an excel letter-number address into a useful array address
# @note that also Excel uses X-Y notation, we normally use Y-X in arrays
# @args $str, excel coord eg. A2
# @returns an array - 2 elements - column, row, or undefined
#
sub sheetRef {
    my $str = shift;
    my @ret;

    $str =~ m/^(\D+)(\d+)$/
        or croak "Invalid cell address '$str'";

    if ( $1 && $2 ) {
        push( @ret, $2 - 1, col2int($1) );
    }
    if ( $ret[0] < 0 ) {
        undef @ret;
    }

    return @ret;
}

sub _parse_printareas( $self, $printarea ) {
    my $res = [];

    while( $printarea =~ m!(?:'[^']+'|\w+)\.([A-Z]+)(\d+):(?:'[^']+'|\w+)\.([A-Z]+)(\d+)(?: |$)!gc) {
        my( $w, $n, $e, $s ) = ($1,$2,$3,$4);
        push @$res, [ $n-1, col2int($w), $s-1, col2int($e)];
    };

    return $res
}

=head2 C<< ->parse( %options ) >>

    my $workbook = Spreadsheet::ParseODS->new()->parse( 'example.ods' );

Reads the spreadsheet into memory and returns the data as a
L<Spreadsheet::ParseODS::Workbook> object.

=head3 Options

=over 4

=item *

B<inputtype> - the type of file if passing a filehandle. Can be C<ods>, C<sxc>
, C<fods> or C<xml>.

=back

This method also takes the same options as the constructor.

=cut

sub parse {
    my( $self, $source, @options ) = @_;
    my %options;
    my $formatter;
    if( @options % 2 == 0 ) {
        %options = @options
    } elsif( @options == 1 ) {
        ($formatter) = @options;
    } else {
        croak "Odd number of values passed to \%options hash";
    };

    if( $options{ attr }) {
        die "We want to store cell attributes";
    };

    my $p = $self->twig;

    my $readonly = $self->readonly;
    if( exists $options{ readonly }) {
        $readonly = $options{ readonly };
    };

    # Convert to ref, later
    my %workbook = ();
    my @worksheets = ();
    my @sheet_order = ();
    my %table_styles;
    my $styles = Spreadsheet::ParseODS::Styles->new(); # the workbook style
    my %settings;

    my %handlers;
    my %style_handlers;
    my %setting_handlers;

    $setting_handlers{ '//office:settings/config:config-item-set[@config:name="ooo:view-settings"]//config:config-item' } = sub {
        my( $twig, $setting ) = @_;
        if( $setting->att('config:name') eq 'ActiveTable' ) {
            $settings{ active_sheet_name } = $setting->text;
        };
    };

    $handlers{ "//office:automatic-styles/style:style" } = sub {
        my( $twig, $style ) = @_;
        #die sprintf "Style '%s' already exists!", $style->att('style:name')
        #    if $table_styles{ $style->att('style:name') };
        my $style_name = $style->att('style:name');
        #warn sprintf "Defining data-style for '%s' as '%s'", $style_name, $style->att('style:data-style-name');
        #if( ! $style->att('style:data-style-name') ) {
        #    warn "Inline style?!";
        #    warn $style->toString;
        #};
            $table_styles{ $style_name } = $style;
        #warn join ", ", sort keys %table_styles;
    };

    $handlers{ "//office:automatic-styles" } =
    $style_handlers{ "//office:automatic-styles" } = sub {
        my( $twig, $style ) = @_;
        $styles->read_from_twig( $style );
    };

    if( 0 ) {
        # In case we have an FODS XML file where all sub-parts are contained within
        # the same XML
        $handlers{ "//office:styles" } = sub {
            my( $twig, $style ) = @_;
            $styles->read_from_twig( $style );
        };
    };

    $handlers{ "table:table" } = sub {
        my( $twig, $table ) = @_;

        my $max_datarow = -1;
        my $max_datacol = -1;
        my @hidden_cols = ();
        my @hidden_rows = ();

        my $tablename = $table->att('table:name');
        my $tableref = $workbook{ $tablename } = [];
        my $table_hidden = $table->att( 'table:visibility' ); # SXC
        my $tab_color;
        if( my $style_name = $table->att('table:style-name')) {
            my $style = $table_styles{$style_name};
            die "No style for '$style_name'" unless $style;
            if( my $prop = $style->first_child('style:table-properties')) {
                my $display = $prop->att('table:display')
                        || '';
                $table_hidden = $display eq 'false' ? 1 : undef;
                $tab_color = $prop->att('tableooo:tab-color');
            };
        };

        my $print_areas;
        # we currently only support one
        if( my $print_area_attr = $table->att( 'table:print-ranges' )) {
            $print_areas = $self->_parse_printareas($print_area_attr);
        };

        # Collect information on header columns
        my @column_default_styles;
        my ($header_col_start, $header_col_end) = (undef,undef);
        my $colnum = -1;
        for my $col ($table->findnodes('.//table:table-column')) {
            $colnum++;

            my $repeat = $col->att('table:number-columns-repeated') || 1;

            if( my $style = $col->att('table:default-cell-style-name')) {
                push @column_default_styles, ($style) x $repeat;
            } else {
                push @column_default_styles, (undef) x $repeat;
            };

            if( $col->parent->tag eq 'table:table-header-columns' ) {
                $header_col_start = $colnum
                    unless defined $header_col_start;
                $header_col_end = $colnum+$repeat-1;
            };
            $colnum += $repeat;

            # if columns is hidden, add column number to @hidden_cols array for later use
            my $col_visibility = $col->att('table:visibility') || '';
            for (1..$repeat) {
                push @hidden_cols, $col_visibility eq 'collapse';
            };
        };

        my ($header_row_start, $header_row_end) = (undef,undef);
        my @rows = $table->findnodes('.//table:table-row');
        # Optimization hack: Find the last row that contains something
        # This is necessary because a formatted column extends 1.000.000 rows
        # downwards
        my $last_payload_row = $#rows;
        while( $last_payload_row >= 0
               and !$rows[ $last_payload_row ]->findnodes('*[@office:value-type] | *[@table:value-type] | .//text:p')) {
            $last_payload_row--
        };

        # Cut away the empty rows
        $last_payload_row++ if $last_payload_row == -1;
        splice @rows, $last_payload_row+1;

        for my $row (@rows) {
            my $row_hidden = $row->att( 'table:visibility' ) || '';

            my $rowref = [];

            # Do we really only want to add a cell if it contains text?!
            for my $cell ($row->findnodes("./table:table-cell | ./table:covered-table-cell")) {
                my $colnum = @$rowref;
                my $style_name =    $cell->att('table:style-name')
                                 || $column_default_styles[ $colnum ];
                                 # If there are repeats, they will respect
                                 # changing styles anyway

                my ($text);
                my $type =     $cell->att("office:value-type") # ODS
                            || $cell->att("table:value-type")  # SXC
                            || '' ;
                my ($unformatted) = grep { defined($_) }
                               $cell->att("office:value"), # ODS
                               $cell->att("table:value"),  # SXC
                               $cell->att("office:date-value"), # ODS
                               $cell->att("table:date-value"),  # SXC
                               ;
                my $formula = $cell->att("table:formula");
                if( $formula ) {
                    $formula =~ s!^of:!!;
                };

                my $hyperlink;
                my @hyperlink = $cell->findnodes('.//text:a');
                if( @hyperlink ) {
                    $hyperlink = $hyperlink[0]->att('xlink:href');
                };

                my $repeat = $cell->att('table:number-columns-repeated') || 1;

                my @text = $cell->findnodes('text:p');
                if( @text ) {
                    $text = join $self->line_separator, map { $_->text } @text;
                    $max_datacol = max( $max_datacol, $#$rowref+$repeat );
                } else {
                    $text = $unformatted;
                };

                for my $i (1..$repeat) {
                    # Yes, this is somewhat inefficient, but it saves us
                    # from later programming errors if we create/store
                    # references. We can always later turn this inside-out.
                    if( $cell->is_empty ) {
                        push @$rowref, Spreadsheet::ParseODS::Cell->new({
                            type        => undef,
                            unformatted => undef,
                            value       => undef,
                            formula     => undef,
                            hyperlink   => undef,
                            style       => undef,
                            format      => undef,
                        });

                    } else {

                        if( $type ) {
                            # $row_has_content = 1;
                        };

                        my $f;
                        if( "Default" ne $style_name ) {
                            my $s = $table_styles{ $style_name }->att('style:data-style-name');
                            if( $s ) {
                                $f = $styles->styles->{ $s }->{format};
                            } else {
                                    #warn "<<$style_name>>";
                                    #warn "<<$s>>";
                                    #use Data::Dumper;
                                    #warn Dumper $styles->styles;
                                    #die;
                            };
                        };

                        my $cell = Spreadsheet::ParseODS::Cell->new({
                                  value       => $text,
                                  unformatted => $unformatted,
                                  formula     => $formula,
                                  type        => $type,
                                  hyperlink   => $hyperlink,
                                  style       => $style_name,
                            maybe 'format'    => $f,
                        });

                        push @$rowref, $cell;
                    };
                };
            };

            # if number-rows-repeated is set, set $repeat_rows value accordingly for later use
            my $row_repeat = $row->att('table:number-rows-repeated') || 1;

            for my $r (1..$row_repeat) {
                # clone the row unless there are no more repeated rows
                #push @$tableref, $r < $row_repeat ? dclone( $rowref ) : $rowref;
                # This is nasty but about 5 times faster than calling dclone()
                if( $readonly ) {
                    push @$tableref, $rowref;
                } else {
                    push @$tableref, $r < $row_repeat ? [map { bless { %$_ } => 'Spreadsheet::ParseODS::Cell'; } @$rowref ]: $rowref;
                };
                push @hidden_rows, $row_hidden;
                $max_datarow++;
            };

            if( $row->parent->tag eq 'table:table-header-rows' ) {
                $header_row_start = $#$tableref
                    unless defined $header_row_start;
                $header_row_end = $#$tableref;
            };
        }

        # truncate/expand table to $max_datarow and $max_datacol
        if ( ! $self->NoTruncate ) {
            $#{$tableref} = $max_datarow;
            foreach ( @{$tableref} ) {
                $#{$_} = $max_datacol;
            }
        }

        @$tableref = ()
            if $max_datacol < 0;

        my $header_rows;
        if( defined $header_row_start ) {
            $header_rows = [$header_row_start, $header_row_end];
        };
        my $header_cols;
        if( defined $header_col_start ) {
            $header_cols = [$header_col_start, $header_col_end];
        };

        my $ws = Spreadsheet::ParseODS::Worksheet->new({
                label => $tablename,
                tab_color => $tab_color,
                sheet_hidden => $table_hidden,
                print_areas  => $print_areas,
                data  => \@{$workbook{$tablename}},
                col_min => 0,
                col_max => $max_datacol,
                row_min => 0,
                row_max => $max_datarow,
                header_rows => $header_rows,
                header_cols => $header_cols,
                hidden_rows => \@hidden_rows,
                hidden_cols => \@hidden_cols,
                table_styles => \%table_styles,
        });
        # set up alternative data structure
        push @worksheets, $ws;
        $workbook{ $tablename } = $ws;
    };

    my $options = {};

    # if we don't have an FODS monolithic file, read the styles separately
    if( !$options{ inputtype } or $options{ inputtype } ne 'xml' ) {
        my ($method, $xml) = $self->_open_xml_thing(
                                $source,
                                $options,
                                inputtype => $options{ inputtype },
                                member_file => 'styles.xml',
                            );
        $p->setTwigHandlers( \%style_handlers );
        $p->$method( $xml );

        # read /settings.xml in addition, to fill stuff like ActiveSheet
        ($method, $xml) = $self->_open_xml_thing(
                                $source,
                                $options,
                                inputtype => $options{ inputtype },
                                member_file => 'settings.xml',
                            );
        $p->setTwigHandlers( \%setting_handlers );
        $p->$method( $xml );
        # Also maybe read /meta.xml for the remaining information

    };
    $p->setTwigHandlers( \%handlers );
    my ($method, $xml) = $self->_open_xml_thing(
                            $source,
                            $options,
                            inputtype => $options{ inputtype },
                            member_file => 'content.xml',
                         );
    $p->$method( $xml );

    return Spreadsheet::ParseODS::Workbook->new(
            %$options,
          _worksheets => \%workbook,
              _sheets => \@worksheets,
            _settings => Spreadsheet::ParseODS::Settings->new( %settings ),
        maybe _styles => $styles,
    );
};

sub _open_xml_thing( $self, $source, $wb_info, %options ) {
    my $ref = ref($source);
    my $xml;
    my $method = 'parse';
    if( ! $ref ) {
        # Specified by filename .
        croak "Undef ODS source given"
            unless defined $source;

        $wb_info->{filename} = $source;
        if( $source =~ m!(\.xml|\.fods)!i or ($options{ inputtype } and $options{ inputtype } =~ m!^(xml|fods)$! )) {
            $method = 'parsefile';
            $xml = $source;

        } else {
            $xml = $self->_open_sxc( $source, \%options )
        };

    } else {
        if ( $ref eq 'SCALAR' ) {
            # Specified by a scalar buffer.
            # We create a copy here. Maybe we should be able to feed
            # this to XML::Twig without creating (another) copy here?
            # Or will CoW save us here anyway?

            if( ($options{ inputtype } and $options{ inputtype } =~ m!^(xml|fods)$! )) {
                $xml = $$source;
            } else {
                open my $fh, '<', $source;
                $xml = $self->_open_sxc_fh( $fh, $options{member_file} );
            };

        } elsif ( $ref eq 'ARRAY' ) {
            # Specified by file content
            if( ($options{ inputtype } and $options{ inputtype } =~ m!^(xml|fods)$! )) {
                $xml = join( '', @$source );
            } else {
                my $content = join( '', @$source );
                open my $fh, '<', $content;
                $xml = $self->_open_sxc_fh( $fh, $options{member_file} );
            };

        } else {
             # Assume filehandle
             # Kick off XML::Twig from Filehandle
             #warn "Duplicated source";
             open my $fh, '<&', $source;
             $xml = $self->_open_sxc_fh( $fh, $options{ member_file });
         }
    }

    return ($method, $xml)
}

sub _open_sxc {
    my ($self, $sxc_file, $options_ref) = @_;
    if( !$options_ref->{StrictErrors}) {
        -f $sxc_file && -s _ or return undef;
    };
    open my $fh, '<', $sxc_file
        or croak "Couldn't open '$sxc_file': $!";
    return $self->_open_sxc_fh( $fh, $options_ref->{member_file} );
}

sub _open_sxc_fh($self, $fh, $member) {
    my $zip = Archive::Zip->new();
    my $status = $zip->readFromFileHandle($fh);
    $status == AZ_OK
        or croak "Read error from zip";
    my $content = $zip->memberNamed($member)
        or croak "Want to read $member' but it doesn't exist!";

    $content->rewindData();
    my $stream = $content->fh;
    1 if eof($stream); # reset eof state of $stream?! Is that a bug? Where?
    binmode $stream => ':gzip(none)';
    return $stream
}

sub _build_styles( $self, $styles ) {
    return Spreadsheet::ParseODS::Styles->new()
}

1;
