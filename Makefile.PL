use strict;
use warnings;
use inc::Module::Install;

name            'Sledge-Plugin-Pager';
all_from        'lib/Sledge/Plugin/Pager.pm';

requires 'Lingua::EN::Inflect' => 0;
requires 'String::CamelCase' => 0;
build_requires 'Test::Base' => 0;
build_requires 'Class::DBI' => 0;
build_requires 'Class::DBI::Pager' => 0;
build_requires 'Test::Dependencies' => 0;

use_test_base;
auto_install;
WriteAll;

