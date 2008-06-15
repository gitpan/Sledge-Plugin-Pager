package t::TestSledge;
use strict;
use warnings;
use Test::Base -base;

sub run_sledge {
    run {
        my $block = shift;

        no warnings 'once';
        local *t::TestPages::dispatch_test = sub {
            my $self = shift;
            eval $block->input;
            die $@ if $@;
        };

        my $page = t::TestPages->new;
        $page->dispatch('test');
        is($page->output, $block->expected, $block->name);
    };
}

package t::TestPages;
use strict;
use warnings;
require Sledge::TestPages;
use base qw/Sledge::TestPages/;

my $x;
$x = $t::TestPages::TMPL_PATH = 't/';
$x = $t::TestPages::COOKIE_NAME = 'sid';
$ENV{HTTP_COOKIE}    = "sid=SIDSIDSIDSID";
$ENV{REQUEST_METHOD} = 'GET';
$ENV{QUERY_STRING}   = 'foo=bar';

1;
