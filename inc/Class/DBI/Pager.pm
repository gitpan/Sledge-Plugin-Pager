#line 1
package Class::DBI::Pager;

use strict;
use vars qw($VERSION $AUTOLOAD);
$VERSION = 0.08;

use Class::DBI 0.90;
use Data::Page;

sub import {
    my $class = shift;
    my $pkg   = caller(0);
    no strict 'refs';
    *{"$pkg\::pager"} = \&_pager;
}

sub _croak { require Carp; Carp::croak(@_); }

sub _pager {
    my($pkg, $entry, $curr) = @_;
    bless {
	pkg   => $pkg,
	entry => $entry,
	curr  => $curr,
	pager => undef,
    }, __PACKAGE__;
}

BEGIN {
    my @methods = qw(total_entries entries_per_page current_page entries_on_this_page
		     first_page last_page first last previous_page next_page pages_in_navigation);
    for my $method (@methods) {
	no strict 'refs';
	*$method = sub {
	    my $self = shift;
	    $self->{pager} or _croak("Can't call pager methods without searching");
	    $self->{pager}->$method(@_);
	};
    }
}

sub DESTROY { }

sub AUTOLOAD {
    my $self = shift;
    (my $method = $AUTOLOAD) =~ s/.*://;
    if (ref($self) && $self->{pkg}->can($method)) {
	my $iter  = $self->{pkg}->$method(@_);
	UNIVERSAL::isa($iter, 'Class::DBI::Iterator')
	    or _croak("$method doesn't return Class::DBI::Itertor");
	my $pager = $self->{pager} = Data::Page->new(
	    $iter->count, $self->{entry}, $self->{curr},
	);
	return $iter->slice($pager->first-1, $pager->last-1);
    }
    else {
	_croak(qq(Can't locate object method "$method" via package ) . ref($self) || $self);
    }
}

1;
__END__

#line 151
