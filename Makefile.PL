use inc::Module::Install;
name 'Sledge-Plugin-Pager';
all_from 'lib/Sledge/Plugin/Pager.pm';

requires 'Lingua::EN::Inflect' => 0;
requires 'String::CamelCase' => 0;

test_requires 'Test::Base' => 0;
test_requires 'Class::DBI' => 0;
test_requires 'Class::DBI::Pager' => 0;
test_requires 'Sledge::TestPages' => 0;

tests 't/*.t t/*/*.t t/*/*/*.t t/*/*/*/*.t';
test_requires 'Test::More';
test_requires 'YAML';
author_tests 'xt';
use_test_base;
auto_include;
WriteAll;
