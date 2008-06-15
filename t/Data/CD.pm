package t::Data::CD;
use strict;
use warnings;
use Class::DBI;
require Class::DBI::Test::SQLite;
use base 'Class::DBI::Test::SQLite';
use Class::DBI::Pager;

__PACKAGE__->set_table('cdd');
__PACKAGE__->columns(All => qw/id title artist/);

sub create_sql { 
    return q{
        id     INTEGER PRIMARY KEY,
        title  CHAR(40),
        artist VARCHAR(255)
    }
}

__PACKAGE__->insert(
    {
        title => 'boofy',
        artist => 'BK'
    }
);

__PACKAGE__->insert(
    {
        title => 'not boofy',
        artist => 'bonnu'
    }
);

1;
