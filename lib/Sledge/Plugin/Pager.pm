package Sledge::Plugin::Pager;
use strict;
use warnings;
our $VERSION = '0.02';
use Carp;

sub import {
    my $pkg = caller;

    no strict 'refs'; ## no critic
    *{"$pkg\::pager"} = sub {
        my ( $self, $table, $name ) = @_;

        return Sledge::Plugin::Pager::Pager->new(
            {   page  => $self,
                table => $table,
                name  => $name || undef,
            }
        );
    };
}

# -------------------------------------------------------------------------

package Sledge::Plugin::Pager::Pager;
use strict;
use warnings;
use String::CamelCase qw/decamelize/;
use Lingua::EN::Inflect;

our $REQUEST_PARAM = 'page';

sub new {
    my ($class, $args) = @_;
    bless {%{$args}}, $class;
}

our $AUTOLOAD;
sub DESTROY { }    # nop for AUTOLOAD
sub AUTOLOAD {
    my $self = shift;
    my @args = @_;

    ( my $meth = $AUTOLOAD ) =~ s/.+:://g;

    no strict 'refs'; ## no critic
    *{$AUTOLOAD} = sub {
        my ( $self, @args ) = @_;

        my $page  = $self->{page};
        my $pager = $self->{table}->pager(
            $page->create_config->paging_num,
            $page->r->param($REQUEST_PARAM) || 1,
        );

        my $rows = [ $pager->$meth(@args) ];

        $page->tmpl->param(
            pager             => $pager,
            $self->param_name => $rows,
        );

        # for convinient.
        if ( $page->can('stash') ) {
            $page->stash->{rows} = $rows;
        }
    };

    $AUTOLOAD->($self, @args);
}

sub param_name {
    my $self = shift;

    if ( $self->{name} ) {
        return $self->{name};
    }
    else {
        ( my $table = $self->{table} ) =~ s/.+:://g;
        return Lingua::EN::Inflect::PL( decamelize($table) );
    }
}

1;
__END__

=head1 NAME

Sledge::Plugin::Pager - 

=head1 SYNOPSIS

    package Your::Pages;
    use Sledge::Plugin::Pager;

    sub dispatch_foo {
        my $self = shift;

        $self->pager('Your::Data::CD')->retrive_all;
    }

    # in your template.
    [% FOR cd IN cds %]
        [% cd.title %]
    [% END %]

    [% FOREACH num = [pager.first_page .. pager.last_page] %]
    [% IF num == pager.current_page %][[% num %]]
    [% ELSE %]<a href="display?page=[% num %]">[[% num %]]</a>[% END %]
    [% END %]

=head1 DESCRIPTION

helper plugin for paginate the Class::DBI model.

=head1 INTERFACE 

=head1 BUGS AND LIMITATIONS

No bugs have been reported.

=head1 AUTHOR

Tokuhiro Matsuno  C<< <tokuhiro __at__ mobilefactory.jp> >>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2006, Tokuhiro Matsuno C<< <tokuhiro __at__ mobilefactory.jp> >>. All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.

