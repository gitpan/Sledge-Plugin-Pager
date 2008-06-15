use strict;
use warnings;
use Test::Base;
BEGIN {
    local $SIG{__WARN__} = sub { };
    eval q[use Class::DBI::Pager;];
    plan skip_all => "Class::DBI::Pager required for testing base: $@" if $@;
    eval q[use Class::DBI::Test::SQLite;];
    plan skip_all => "Class::DBI::Test::SQLite required for testing base: $@" if $@;
    eval q[use Sledge::TestPages;];
    plan skip_all => "Sledge::TestPages required for testing base: $@" if $@;
    eval q[use t::TestSledge;use t::Data::CD];
    plan skip_all => "t::TestSledge, t::Data::CD required for testing base: $@" if $@;
};

plan tests => 1*blocks;

filters( { input => [qw/chomp/], } );


{
    package t::TestPages;
    use Sledge::Plugin::Pager;
}

t::TestSledge::run_sledge();

__END__

=== simple
--- input
$self->pager('t::Data::CD')->retrieve_all;
--- expected
Content-Length: 42
Content-Type: text/html; charset=euc-jp

# cds: boofy,not boofy,
# compact_discs: 

=== autoload cache
--- input
$self->pager('t::Data::CD')->retrieve_all;
$self->pager('t::Data::CD')->retrieve_all;
--- expected
Content-Length: 42
Content-Type: text/html; charset=euc-jp

# cds: boofy,not boofy,
# compact_discs: 

=== set name manually
--- input
$self->pager('t::Data::CD', 'compact_discs')->retrieve_all;
--- expected
Content-Length: 42
Content-Type: text/html; charset=euc-jp

# cds: 
# compact_discs: boofy,not boofy,

