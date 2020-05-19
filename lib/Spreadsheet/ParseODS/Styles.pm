package Spreadsheet::ParseODS::Styles;
use Moo 2;
use Carp qw(croak);
use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';
use PerlX::Maybe;

our $VERSION = '0.24';

=head1 NAME

Spreadsheet::ParseODS::Styles - styles / formatting of cells in a workbook

=cut

has 'styles' => (
    is => 'lazy',
    default => sub { {} },
);

sub part_to_format( $self, $part ) {
    my $t = $part->tag;
    my $res;
    if( $t eq 'number:seconds' ) {
        my $style = $part->att('number:style');
        if( $style and $style eq 'long') {
            $res = 'SS';
        } else {
            $res = 'S';
        };
        #warn $part->toString;
    } elsif( $t eq 'number:minutes' ) {
        my $style = $part->att('number:style');
        if( $style and $style eq 'long') {
            $res = 'MM';
        } else {
            $res = 'M';
        };
        #warn $part->toString;
    } elsif( $t eq 'number:hours' ) {
        my $style = $part->att('number:style');
        if( $style and $style eq 'long') {
            $res = 'HH';
        } else {
            $res = 'H';
        };
        #warn $part->toString;
    } elsif( $t eq 'number:day' ) {
        my $style = $part->att('number:style');
        if( $style and $style eq 'long') {
            $res = 'dd';
        } else {
            $res = 'd';
        };
    } elsif( $t eq 'number:day-of-week' ) {
        my $style = $part->att('number:style');
        $res = 'ddd';
        #warn $part->toString;
    } elsif( $t eq 'number:month' ) {
        my $style = $part->att('number:style');
        my $month_name = $part->att('number:textual');
        if( $month_name and $month_name eq 'true') {
            $res = 'mmm';
        } elsif( $style and $style eq 'long') {
            $res = 'mm';
        } else {
            $res = 'm';
        };
        #warn $part->toString;
    } elsif( $t eq 'number:year' ) {
        my $style = $part->att('number:style');
        if( $style and $style eq 'long') {
            $res = 'yyyy';
        } else {
            $res = 'yy';
        };
        #warn $part->toString;
    } elsif( $t eq 'number:number' ) {
        $res = '#' x $part->att('number:min-integer-digits');

        if( defined( my $dec = $part->att('number:decimal-places'))) {
            $res .= '.' . ('0' x $dec);
        };
        #warn $part->toString;
    } elsif( $t eq 'number:text' ) {
        $res = $part->text;
    } elsif( $t eq 'number:text-content' or $t eq 'number:currency-symbol' ) {
        $res = $part->text;
    } elsif( $t eq 'loext:text' ) {
        $res = $part->text;
    } elsif( $t eq 'loext:fill-character' ) {
        # ignored
    } else {
        warn "Unknown tag name '$t'";
    };
    return $res
}

sub to_format( $self, $style ) {
    return join "", map { $self->part_to_format( $_ ) } $style->children
}

sub read_from_twig( $self, $elt ) {
    my $styles = $self->styles;

    for my $style ($elt->findnodes(join " | ",
        '//style:default-style',
        '//number:date-style',
        '//number:number-style',
        '//number:text-style',
        '//number:time-style',
        '//number:currency-style',
    )) {
        my $name =  $style->att('style:data-style-name')
                 || $style->att('style:name');

        # Currently we simply ignore the default style...
        next unless defined $name;

        # ignore language and country
        # This is not ideal, but oh well
        my $format = $self->to_format( $style );
warn "Defined '$name' as '$format'";
warn $style->toString unless $format;
        $styles->{ $name } = {
            format => $format,
        };
    };

}

1;
