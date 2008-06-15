#line 1
package Class::DBI::__::Base;

require 5.006;

use Class::Trigger 0.07;
use base qw(Class::Accessor Class::Data::Inheritable Ima::DBI);

package Class::DBI;

use version; $VERSION = qv('3.0.17');

use strict;
use warnings;

use base "Class::DBI::__::Base";

use Class::DBI::ColumnGrouper;
use Class::DBI::Query;
use Carp ();
use List::Util;
use Clone ();
use UNIVERSAL::moniker;

use vars qw($Weaken_Is_Available);

BEGIN {
	$Weaken_Is_Available = 1;
	eval {
		require Scalar::Util;
		import Scalar::Util qw(weaken);
	};
	if ($@) {
		$Weaken_Is_Available = 0;
	}
}

use overload
	'""'     => sub { shift->stringify_self },
	bool     => sub { not shift->_undefined_primary },
	fallback => 1;

sub stringify_self {
	my $self = shift;
	return (ref $self || $self) unless $self;    # empty PK
	my @cols = $self->columns('Stringify');
	@cols = $self->primary_columns unless @cols;
	return join "/", $self->get(@cols);
}

sub _undefined_primary {
	my $self = shift;
	return grep !defined, $self->_attrs($self->primary_columns);
}

#----------------------------------------------------------------------
# Deprecations
#----------------------------------------------------------------------

__PACKAGE__->mk_classdata('__hasa_rels' => {});

{
	my %deprecated = (
   # accessor_name => 'accessor_name_for', # 3.0.7
   # mutator_name  => 'accessor_name_for', # 3.0.7
  );

	no strict 'refs';
	while (my ($old, $new) = each %deprecated) {
		*$old = sub {
			my @caller = caller;
			warn
				"Use of '$old' is deprecated at $caller[1] line $caller[2]. Use '$new' instead\n";
			goto &$new;
		};
	}
}

#----------------------------------------------------------------------
# Our Class Data
#----------------------------------------------------------------------
__PACKAGE__->mk_classdata('__AutoCommit');
__PACKAGE__->mk_classdata('__hasa_list');
__PACKAGE__->mk_classdata('_table');
__PACKAGE__->mk_classdata('_table_alias');
__PACKAGE__->mk_classdata('sequence');
__PACKAGE__->mk_classdata('__grouper'   => Class::DBI::ColumnGrouper->new());
__PACKAGE__->mk_classdata('__data_type' => {});
__PACKAGE__->mk_classdata('__driver');
__PACKAGE__->mk_classdata('iterator_class' => 'Class::DBI::Iterator');
__PACKAGE__->mk_classdata('purge_object_index_every' => 1000);
__PACKAGE__->add_searcher(search => "Class::DBI::Search::Basic",);

__PACKAGE__->add_relationship_type(
	has_a      => "Class::DBI::Relationship::HasA",
	has_many   => "Class::DBI::Relationship::HasMany",
	might_have => "Class::DBI::Relationship::MightHave",
);
__PACKAGE__->mk_classdata('__meta_info' => {});

#----------------------------------------------------------------------
# SQL we'll need
#----------------------------------------------------------------------
__PACKAGE__->set_sql(MakeNewObj => <<'');
INSERT INTO __TABLE__ (%s)
VALUES (%s)

__PACKAGE__->set_sql(update => <<"");
UPDATE __TABLE__
SET    %s
WHERE  __IDENTIFIER__

__PACKAGE__->set_sql(Nextval => <<'');
SELECT NEXTVAL ('%s')

__PACKAGE__->set_sql(SearchSQL => <<'');
SELECT %s
FROM   %s
WHERE  %s

__PACKAGE__->set_sql(RetrieveAll => <<'');
SELECT __ESSENTIAL__
FROM   __TABLE__

__PACKAGE__->set_sql(Retrieve => <<'');
SELECT __ESSENTIAL__
FROM   __TABLE__
WHERE  %s

__PACKAGE__->set_sql(Flesh => <<'');
SELECT %s
FROM   __TABLE__
WHERE  __IDENTIFIER__

__PACKAGE__->set_sql(single => <<'');
SELECT %s
FROM   __TABLE__

__PACKAGE__->set_sql(DeleteMe => <<"");
DELETE
FROM   __TABLE__
WHERE  __IDENTIFIER__


__PACKAGE__->mk_classdata('sql_transformer_class');
__PACKAGE__->sql_transformer_class('Class::DBI::SQL::Transformer');

# Override transform_sql from Ima::DBI to provide some extra
# transformations
sub transform_sql {
	my ($self, $sql, @args) = @_;
	my $tclass = $self->sql_transformer_class;
	$self->_require_class($tclass);
	my $T = $tclass->new($self, $sql, @args);
	return $self->SUPER::transform_sql($T->sql => $T->args);
}

#----------------------------------------------------------------------
# EXCEPTIONS
#----------------------------------------------------------------------

sub _carp {
	my ($self, $msg) = @_;
	Carp::carp($msg || $self);
	return;
}

sub _croak {
	my ($self, $msg) = @_;
	Carp::croak($msg || $self);
}

sub _db_error {
	my ($self, %info) = @_;
	my $msg = delete $info{msg};
	return $self->_croak($msg, %info);
}

#----------------------------------------------------------------------
# SET UP
#----------------------------------------------------------------------

sub connection {
	my $class = shift;
	$class->set_db(Main => @_);
}

{
	my %Per_DB_Attr_Defaults = (
		pg     => { AutoCommit => 0 },
		oracle => { AutoCommit => 0 },
	);

	sub _default_attributes {
		my $class = shift;
		return (
			$class->SUPER::_default_attributes,
			FetchHashKeyName   => 'NAME_lc',
			ShowErrorStatement => 1,
			AutoCommit         => 1,
			ChopBlanks         => 1,
			%{ $Per_DB_Attr_Defaults{ lc $class->__driver } || {} },
		);
	}
}

sub set_db {
	my ($class, $db_name, $data_source, $user, $password, $attr) = @_;

	# 'dbi:Pg:dbname=foo' we want 'Pg'. I think this is enough.
	my ($driver) = $data_source =~ /^dbi:(\w+)/i;
	$class->__driver($driver);
	$class->SUPER::set_db('Main', $data_source, $user, $password, $attr);
}

sub table {
	my ($proto, $table, $alias) = @_;
	my $class = ref $proto || $proto;
	$class->_table($table)      if $table;
	$class->table_alias($alias) if $alias;
	return $class->_table || $class->_table($class->table_alias);
}

sub table_alias {
	my ($proto, $alias) = @_;
	my $class = ref $proto || $proto;
	$class->_table_alias($alias) if $alias;
	return $class->_table_alias || $class->_table_alias($class->moniker);
}

sub columns {
	my $proto = shift;
	my $class = ref $proto || $proto;
	my $group = shift || "All";
	return $class->_set_columns($group => @_) if @_;
	return $class->all_columns    if $group eq "All";
	return $class->primary_column if $group eq "Primary";
	return $class->_essential     if $group eq "Essential";
	return $class->__grouper->group_cols($group);
}

sub _column_class { 'Class::DBI::Column' }

sub _set_columns {
	my ($class, $group, @columns) = @_;

	my @cols = map ref $_ ? $_ : $class->_column_class->new($_), @columns;

	# Careful to take copy
	$class->__grouper(Class::DBI::ColumnGrouper->clone($class->__grouper)
			->add_group($group => @cols));
	$class->_mk_column_accessors(@cols);
	return @columns;
}

sub all_columns { shift->__grouper->all_columns }

sub id {
	my $self  = shift;
	my $class = ref($self)
		or return $self->_croak("Can't call id() as a class method");

	# we don't use get() here because all objects should have
	# exisitng values for PK columns, or else loop endlessly
	my @pk_values = $self->_attrs($self->primary_columns);
	UNIVERSAL::can($_ => 'id') and $_ = $_->id for @pk_values;
	return @pk_values if wantarray;
	$self->_croak(
		"id called in scalar context for class with multiple primary key columns")
		if @pk_values > 1;
	return $pk_values[0];
}

sub primary_column {
	my $self            = shift;
	my @primary_columns = $self->__grouper->primary;
	return @primary_columns if wantarray;
	$self->_carp(
		ref($self)
			. " has multiple primary columns, but fetching in scalar context")
		if @primary_columns > 1;
	return $primary_columns[0];
}
*primary_columns = \&primary_column;

sub _essential { shift->__grouper->essential }

sub find_column {
	my ($class, $want) = @_;
	return $class->__grouper->find_column($want);
}

sub _find_columns {
	my $class = shift;
	my $cg    = $class->__grouper;
	return map $cg->find_column($_), @_;
}

sub has_real_column {    # is really in the database
	my ($class, $want) = @_;
	return ($class->find_column($want) || return)->in_database;
}

sub data_type {
	my $class    = shift;
	my %datatype = @_;
	while (my ($col, $type) = each %datatype) {
		$class->_add_data_type($col, $type);
	}
}

sub _add_data_type {
	my ($class, $col, $type) = @_;
	my $datatype = $class->__data_type;
	$datatype->{$col} = $type;
	$class->__data_type($datatype);
}

# Make a set of accessors for each of a list of columns. We construct
# the method name by calling accessor_name_for() and mutator_name_for()
# with the normalized column name.

# mutator name will be the same as accessor name unless you override it.

# If both the accessor and mutator are to have the same method name,
# (which will always be true unless you override mutator_name_for), a
# read-write method is constructed for it. If they differ we create both
# a read-only accessor and a write-only mutator.

sub _mk_column_accessors {
	my $class = shift;
	foreach my $col (@_) {

		my $default_accessor = $col->accessor;

		my $acc = $class->accessor_name_for($col);
		my $mut = $class->mutator_name_for($col);

		my %method = ();

		if (
			($acc    eq $mut)                # if they are the same
			or ($mut eq $default_accessor)
			) {                              # or only the accessor was customized
			%method = ('_' => $acc);         # make the accessor the mutator too
			$col->accessor($acc);
			$col->mutator($acc);
			} else {
			%method = (
				_ro_ => $acc,
				_wo_ => $mut,
			);
			$col->accessor($acc);
			$col->mutator($mut);
		}

		foreach my $type (keys %method) {
			my $name     = $method{$type};
			my $acc_type = "make${type}accessor";
			my $accessor = $class->$acc_type($col->name_lc);
			$class->_make_method($_, $accessor) for ($name, "_${name}_accessor");
		}
	}
}

sub _make_method {
	my ($class, $name, $method) = @_;
	return if defined &{"$class\::$name"};
	$class->_carp("Column '$name' in $class clashes with built-in method")
		if Class::DBI->can($name)
		and not($name eq "id" and join(" ", $class->primary_columns) eq "id");
	no strict 'refs';
	*{"$class\::$name"} = $method;
	$class->_make_method(lc $name => $method);
}

sub accessor_name_for {
	my ($class, $column) = @_;
  if ($class->can('accessor_name')) { 
		warn "Use of 'accessor_name' is deprecated. Use 'accessor_name_for' instead\n";
		return $class->accessor_name($column) 
	}
	return $column->accessor;
}

sub mutator_name_for {
	my ($class, $column) = @_;
  if ($class->can('mutator_name')) { 
		warn "Use of 'mutator_name' is deprecated. Use 'mutator_name_for' instead\n";
		return $class->mutator_name($column) 
	}
	return $column->mutator;
}

sub autoupdate {
	my $proto = shift;
	ref $proto ? $proto->_obj_autoupdate(@_) : $proto->_class_autoupdate(@_);
}

sub _obj_autoupdate {
	my ($self, $set) = @_;
	my $class = ref $self;
	$self->{__AutoCommit} = $set if defined $set;
	defined $self->{__AutoCommit}
		? $self->{__AutoCommit}
		: $class->_class_autoupdate;
}

sub _class_autoupdate {
	my ($class, $set) = @_;
	$class->__AutoCommit($set) if defined $set;
	return $class->__AutoCommit;
}

sub make_read_only {
	my $proto = shift;
	$proto->add_trigger("before_$_" => sub { _croak "$proto is read only" })
		foreach qw/create delete update/;
	return $proto;
}

sub find_or_create {
	my $class    = shift;
	my $hash     = ref $_[0] eq "HASH" ? shift: {@_};
	my ($exists) = $class->search($hash);
	return defined($exists) ? $exists : $class->insert($hash);
}

sub insert {
	my $class = shift;
	return $class->_croak("insert needs a hashref") unless ref $_[0] eq 'HASH';
	my $info = { %{ +shift } };    # make sure we take a copy

	my $data;
	while (my ($k, $v) = each %$info) {
		my $col = $class->find_column($k)
			|| (List::Util::first { $_->mutator  eq $k } $class->columns)
			|| (List::Util::first { $_->accessor eq $k } $class->columns)
			|| $class->_croak("$k is not a column of $class");
		$data->{$col} = $v;
	}

	$class->normalize_column_values($data);
	$class->validate_column_values($data);
	return $class->_insert($data);
}

*create = \&insert;

#----------------------------------------------------------------------
# Low Level Data Access
#----------------------------------------------------------------------

sub _attrs {
	my ($self, @atts) = @_;
	return @{$self}{@atts};
}
*_attr = \&_attrs;

sub _attribute_store {
	my $self   = shift;
	my $vals   = @_ == 1 ? shift: {@_};
	my (@cols) = keys %$vals;
	@{$self}{@cols} = @{$vals}{@cols};
}

# If you override this method, you must use the same mechanism to log changes
# for future updates, as other parts of Class::DBI depend on it.
sub _attribute_set {
	my $self = shift;
	my $vals = @_ == 1 ? shift: {@_};

	# We increment instead of setting to 1 because it might be useful to
	# someone to know how many times a value has changed between updates.
	for my $col (keys %$vals) { $self->{__Changed}{$col}++; }
	$self->_attribute_store($vals);
}

sub _attribute_delete {
	my ($self, @attributes) = @_;
	delete @{$self}{@attributes};
}

sub _attribute_exists {
	my ($self, $attribute) = @_;
	exists $self->{$attribute};
}

#----------------------------------------------------------------------
# Live Object Index (using weak refs if available)
#----------------------------------------------------------------------

my %Live_Objects;
my $Init_Count = 0;

sub _init {
	my $class = shift;
	my $data  = shift || {};
	my $key   = $class->_live_object_key($data);
	return $Live_Objects{$key} || $class->_fresh_init($key => $data);
}

sub _fresh_init {
	my ($class, $key, $data) = @_;
	my $obj = bless {}, $class;
	$obj->_attribute_store(%$data);

	# don't store it unless all keys are present
	if ($key && $Weaken_Is_Available) {
		weaken($Live_Objects{$key} = $obj);

		# time to clean up your room?
		$class->purge_dead_from_object_index
			if ++$Init_Count % $class->purge_object_index_every == 0;
	}
	return $obj;
}

sub _live_object_key {
	my ($me, $data) = @_;
	my $class   = ref($me) || $me;
	my @primary = $class->primary_columns;

	# no key unless all PK columns are defined
	return "" unless @primary == grep defined $data->{$_}, @primary;

	# create single unique key for this object
	return join "\030", $class, map $_ . "\032" . $data->{$_}, sort @primary;
}

sub purge_dead_from_object_index {
	delete @Live_Objects{ grep !defined $Live_Objects{$_}, keys %Live_Objects };
}

sub remove_from_object_index {
	my $self    = shift;
	my $obj_key = $self->_live_object_key({ $self->_as_hash });
	delete $Live_Objects{$obj_key};
}

sub clear_object_index {
	%Live_Objects = ();
}

#----------------------------------------------------------------------

sub _prepopulate_id {
	my $self            = shift;
	my @primary_columns = $self->primary_columns;
	return $self->_croak(
		sprintf "Can't create %s object with null primary key columns (%s)",
		ref $self, $self->_undefined_primary)
		if @primary_columns > 1;
	$self->_attribute_store($primary_columns[0] => $self->_next_in_sequence)
		if $self->sequence;
}

sub _insert {
	my ($proto, $data) = @_;
	my $class = ref $proto || $proto;

	my $self = $class->_init($data);
	$self->call_trigger('before_create');
	$self->call_trigger('deflate_for_create');

	$self->_prepopulate_id if $self->_undefined_primary;

	# Reinstate data
	my ($real, $temp) = ({}, {});
	foreach my $col (grep $self->_attribute_exists($_), $self->all_columns) {
		($class->has_real_column($col) ? $real : $temp)->{$col} =
			$self->_attrs($col);
	}
	$self->_insert_row($real);

	my @primary_columns = $class->primary_columns;
	$self->_attribute_store(
		$primary_columns[0] => $real->{ $primary_columns[0] })
		if @primary_columns == 1;

	delete $self->{__Changed};

	my %primary_columns;
	@primary_columns{@primary_columns} = ();
	my @discard_columns = grep !exists $primary_columns{$_}, keys %$real;
	$self->call_trigger('create', discard_columns => \@discard_columns);   # XXX

	# Empty everything back out again!
	$self->_attribute_delete(@discard_columns);
	$self->call_trigger('after_create');
	return $self;
}

sub _next_in_sequence {
	my $self = shift;
	return $self->sql_Nextval($self->sequence)->select_val;
}

sub _auto_increment_value {
	my $self = shift;
	my $dbh  = $self->db_Main;

	# Try to do this in a standard method. Fall back to MySQL/SQLite
	# specific versions. TODO remove these when last_insert_id is more
	# widespread.
	# Note: I don't believe the last_insert_id can be zero. We need to
	# switch to defined() checks if it can.
	my $id = $dbh->last_insert_id(undef, undef, $self->table, undef)    # std
		|| $dbh->{mysql_insertid}                                         # mysql
		|| eval { $dbh->func('last_insert_rowid') }
		or $self->_croak("Can't get last insert id");
	return $id;
}

sub _insert_row {
	my $self = shift;
	my $data = shift;
	eval {
		my @columns = keys %$data;
		my $sth     = $self->sql_MakeNewObj(
			join(', ', @columns),
			join(', ', map $self->_column_placeholder($_), @columns),
		);
		$self->_bind_param($sth, \@columns);
		$sth->execute(values %$data);
		my @primary_columns = $self->primary_columns;
		$data->{ $primary_columns[0] } = $self->_auto_increment_value
			if @primary_columns == 1
			&& !defined $data->{ $primary_columns[0] };
	};
	if ($@) {
		my $class = ref $self;
		return $self->_db_error(
			msg    => "Can't insert new $class: $@",
			err    => $@,
			method => 'insert'
		);
	}
	return 1;
}

sub _bind_param {
	my ($class, $sth, $keys) = @_;
	my $datatype = $class->__data_type or return;
	for my $i (0 .. $#$keys) {
		if (my $type = $datatype->{ $keys->[$i] }) {
			$sth->bind_param($i + 1, undef, $type);
		}
	}
}

sub retrieve {
	my $class           = shift;
	my @primary_columns = $class->primary_columns
		or return $class->_croak(
		"Can't retrieve unless primary columns are defined");
	my %key_value;
	if (@_ == 1 && @primary_columns == 1) {
		my $id = shift;
		return unless defined $id;
		return $class->_croak("Can't retrieve a reference") if ref($id);
		$key_value{ $primary_columns[0] } = $id;
	} else {
		%key_value = @_;
		$class->_croak(
			"$class->retrieve(@_) parameters don't include values for all primary key columns (@primary_columns)"
			)
			if keys %key_value < @primary_columns;
	}
	my @rows = $class->search(%key_value);
	$class->_carp("$class->retrieve(@_) selected " . @rows . " rows")
		if @rows > 1;
	return $rows[0];
}

# Get the data, as a hash, but setting certain values to whatever
# we pass. Used by copy() and move().
# This can take either a primary key, or a hashref of all the columns
# to change.
sub _data_hash {
	my $self            = shift;
	my %data            = $self->_as_hash;
	my @primary_columns = $self->primary_columns;
	delete @data{@primary_columns};
	if (@_) {
		my $arg = shift;
		unless (ref $arg) {
			$self->_croak("Need hash-ref to edit copied column values")
				unless @primary_columns == 1;
			$arg = { $primary_columns[0] => $arg };
		}
		@data{ keys %$arg } = values %$arg;
	}
	return \%data;
}

sub _as_hash {
	my $self    = shift;
	my @columns = $self->all_columns;
	my %data;
	@data{@columns} = $self->get(@columns);
	return %data;
}

sub copy {
	my $self = shift;
	return $self->insert($self->_data_hash(@_));
}

#----------------------------------------------------------------------
# CONSTRUCT
#----------------------------------------------------------------------

sub construct {
	my ($proto, $data) = @_;
	my $class = ref $proto || $proto;
	my $self = $class->_init($data);
	$self->call_trigger('select');
	return $self;
}

sub move {
	my ($class, $old_obj, @data) = @_;
	$class->_carp("move() is deprecated. If you really need it, "
			. "you should tell me quickly so I can abandon my plan to remove it.");
	return $old_obj->_croak("Can't move to an unrelated class")
		unless $class->isa(ref $old_obj)
		or $old_obj->isa($class);
	return $class->insert($old_obj->_data_hash(@data));
}

sub delete {
	my $self = shift;
	return $self->_search_delete(@_) if not ref $self;
	$self->remove_from_object_index;
	$self->call_trigger('before_delete');

	eval { $self->sql_DeleteMe->execute($self->id) };
	if ($@) {
		return $self->_db_error(
			msg    => "Can't delete $self: $@",
			err    => $@,
			method => 'delete'
		);
	}
	$self->call_trigger('after_delete');
	undef %$self;
	bless $self, 'Class::DBI::Object::Has::Been::Deleted';
	return 1;
}

sub _search_delete {
	my ($class, @args) = @_;
	$class->_carp(
		"Delete as class method is deprecated. Use search and delete_all instead."
	);
	my $it = $class->search_like(@args);
	while (my $obj = $it->next) { $obj->delete }
	return 1;
}

# Return the placeholder to be used in UPDATE and INSERT queries.
# Overriding this is deprecated in favour of
#   __PACKAGE__->find_column('entered')->placeholder('IF(1, CURDATE(), ?));

sub _column_placeholder {
	my ($self, $column) = @_;
	return $self->find_column($column)->placeholder;
}

sub update {
	my $self  = shift;
	my $class = ref($self)
		or return $self->_croak("Can't call update as a class method");

	$self->call_trigger('before_update');
	return -1 unless my @changed_cols = $self->is_changed;
	$self->call_trigger('deflate_for_update');
	my @primary_columns = $self->primary_columns;
	my $sth             = $self->sql_update($self->_update_line);
	$class->_bind_param($sth, \@changed_cols);
	my $rows = eval { $sth->execute($self->_update_vals, $self->id); };
	if ($@) {
		return $self->_db_error(
			msg    => "Can't update $self: $@",
			err    => $@,
			method => 'update'
		);
	}

	# enable this once new fixed DBD::SQLite is released:
	if (0 and $rows != 1) {    # should always only update one row
		$self->_croak("Can't update $self: row not found") if $rows == 0;
		$self->_croak("Can't update $self: updated more than one row");
	}

	$self->call_trigger('after_update', discard_columns => \@changed_cols);

	# delete columns that changed (in case adding to DB modifies them again)
	$self->_attribute_delete(@changed_cols);
	delete $self->{__Changed};
	return 1;
}

sub _update_line {
	my $self = shift;
	join(', ', map "$_ = " . $self->_column_placeholder($_), $self->is_changed);
}

sub _update_vals {
	my $self = shift;
	$self->_attrs($self->is_changed);
}

sub DESTROY {
	my ($self) = shift;
	if (my @changed = $self->is_changed) {
		my $class = ref $self;
		$self->_carp("$class $self destroyed without saving changes to "
				. join(', ', @changed));
	}
}

sub discard_changes {
	my $self = shift;
	return $self->_croak("Can't discard_changes while autoupdate is on")
		if $self->autoupdate;
	$self->_attribute_delete($self->is_changed);
	delete $self->{__Changed};
	return 1;
}

# We override the get() method from Class::Accessor to fetch the data for
# the column (and associated) columns from the database, using the _flesh()
# method. We also allow get to be called with a list of keys, instead of
# just one.

sub get {
	my $self = shift;
	return $self->_croak("Can't fetch data as class method") unless ref $self;

	my @cols = $self->_find_columns(@_);
	return $self->_croak("Can't get() nothing!") unless @cols;

	if (my @fetch_cols = grep !$self->_attribute_exists($_), @cols) {
		$self->_flesh($self->__grouper->groups_for(@fetch_cols));
	}

	return $self->_attrs(@cols);
}

sub _flesh {
	my ($self, @groups) = @_;
	my @real = grep $_ ne "TEMP", @groups;
	if (my @want = grep !$self->_attribute_exists($_),
		$self->__grouper->columns_in(@real)) {
		my %row;
		@row{@want} = $self->sql_Flesh(join ", ", @want)->select_row($self->id);
		$self->_attribute_store(\%row);
		$self->call_trigger('select');
	}
	return 1;
}

# We also override set() from Class::Accessor so we can keep track of
# changes, and either write to the database now (if autoupdate is on),
# or when update() is called.
sub set {
	my $self          = shift;
	my $column_values = {@_};

	$self->normalize_column_values($column_values);
	$self->validate_column_values($column_values);

	while (my ($column, $value) = each %$column_values) {
		my $col = $self->find_column($column) or die "No such column: $column\n";
		$self->_attribute_set($col => $value);

		# $self->SUPER::set($column, $value);

		eval { $self->call_trigger("after_set_$column") };    # eg inflate
		if ($@) {
			$self->_attribute_delete($column);
			return $self->_croak("after_set_$column trigger error: $@", err => $@);
		}
	}

	$self->update if $self->autoupdate;
	return 1;
}

sub is_changed {
	my $self = shift;
	grep $self->has_real_column($_), keys %{ $self->{__Changed} };
}

sub any_changed { keys %{ shift->{__Changed} } }

# By default do nothing. Subclasses should override if required.
#
# Given a hash ref of column names and proposed new values,
# edit the values in the hash if required.
# For insert $self is the class name (not an object ref).
sub normalize_column_values {
	my ($self, $column_values) = @_;
}

# Given a hash ref of column names and proposed new values
# validate that the whole set of new values in the hash
# is valid for the object in relation to its current values
# For insert $self is the class name (not an object ref).
sub validate_column_values {
	my ($self, $column_values) = @_;
	my @errors;
	foreach my $column (keys %$column_values) {
		eval {
			$self->call_trigger("before_set_$column", $column_values->{$column},
				$column_values);
		};
		push @errors, $column => $@ if $@;
	}
	return unless @errors;
	$self->_croak(
		"validate_column_values error: " . join(" ", @errors),
		method => 'validate_column_values',
		data   => {@errors}
	);
}

# We override set_sql() from Ima::DBI so it has a default database connection.
sub set_sql {
	my ($class, $name, $sql, $db, @others) = @_;
	$db ||= 'Main';
	$class->SUPER::set_sql($name, $sql, $db, @others);
	$class->_generate_search_sql($name) if $sql =~ /select/i;
	return 1;
}

sub _generate_search_sql {
	my ($class, $name) = @_;
	my $method = "search_$name";
	defined &{"$class\::$method"}
		and return $class->_carp("$method() already exists");
	my $sql_method = "sql_$name";
	no strict 'refs';
	*{"$class\::$method"} = sub {
		my ($class, @args) = @_;
		return $class->sth_to_objects($name, \@args);
	};
}

sub dbi_commit   { my $proto = shift; $proto->SUPER::commit(@_); }
sub dbi_rollback { my $proto = shift; $proto->SUPER::rollback(@_); }

#----------------------------------------------------------------------
# Constraints / Triggers
#----------------------------------------------------------------------

sub constrain_column {
	my $class = shift;
	my $col   = $class->find_column(+shift)
		or return $class->_croak("constraint_column needs a valid column");
	my $how = shift
		or return $class->_croak("constrain_column needs a constraint");
	if (ref $how eq "ARRAY") {
		my %hash = map { $_ => 1 } @$how;
		$class->add_constraint(list => $col => sub { exists $hash{ +shift } });
	} elsif (ref $how eq "Regexp") {
		$class->add_constraint(regexp => $col => sub { shift =~ $how });
	} elsif (ref $how eq "CODE") {
		$class->add_constraint(
			code => $col => sub { local $_ = $_[0]; $how->($_) });
	} else {
		my $try_method = sprintf '_constrain_by_%s', $how->moniker;
		if (my $dispatch = $class->can($try_method)) {
			$class->$dispatch($col => ($how, @_));
		} else {
			$class->_croak("Don't know how to constrain $col with $how");
		}
	}
}

sub add_constraint {
	my $class = shift;
	$class->_invalid_object_method('add_constraint()') if ref $class;
	my $name = shift or return $class->_croak("Constraint needs a name");
	my $column = $class->find_column(+shift)
		or return $class->_croak("Constraint $name needs a valid column");
	my $code = shift
		or return $class->_croak("Constraint $name needs a code reference");
	return $class->_croak("Constraint $name '$code' is not a code reference")
		unless ref($code) eq "CODE";

	$column->is_constrained(1);
	$class->add_trigger(
		"before_set_$column" => sub {
			my ($self, $value, $column_values) = @_;
			$code->($value, $self, $column, $column_values)
				or return $self->_croak(
				"$class $column fails '$name' constraint with '$value'",
				method         => "before_set_$column",
				exception_type => 'constraint_failure',
				data           => {
					column          => $column,
					value           => $value,
					constraint_name => $name,
				}
				);
		}
	);
}

sub add_trigger {
	my ($self, $name, @args) = @_;
	return $self->_croak("on_setting trigger no longer exists")
		if $name eq "on_setting";
	$self->_carp(
		"$name trigger deprecated: use before_$name or after_$name instead")
		if ($name eq "create" or $name eq "delete");
	$self->SUPER::add_trigger($name => @args);
}

#----------------------------------------------------------------------
# Inflation
#----------------------------------------------------------------------

sub add_relationship_type {
	my ($self, %rels) = @_;
	while (my ($name, $class) = each %rels) {
		$self->_require_class($class);
		no strict 'refs';
		*{"$self\::$name"} = sub {
			my $proto = shift;
			$class->set_up($name => $proto => @_);
		};
	}
}

sub _extend_meta {
	my ($class, $type, $subtype, $val) = @_;
	my %hash = %{ Clone::clone($class->__meta_info || {}) };
	$hash{$type}->{$subtype} = $val;
	$class->__meta_info(\%hash);
}

sub meta_info {
	my ($class, $type, $subtype) = @_;
	my $meta = $class->__meta_info;
	return $meta          unless $type;
	return $meta->{$type} unless $subtype;
	return $meta->{$type}->{$subtype};
}

sub _simple_bless {
	my ($class, $pri) = @_;
	return $class->_init({ $class->primary_column => $pri });
}

sub _deflated_column {
	my ($self, $col, $val) = @_;
	$val ||= $self->_attrs($col) if ref $self;
	return $val unless ref $val;
	my $meta = $self->meta_info(has_a => $col) or return $val;
	my ($a_class, %meths) = ($meta->foreign_class, %{ $meta->args });
	if (my $deflate = $meths{'deflate'}) {
		$val = $val->$deflate(ref $deflate eq 'CODE' ? $self : ());
		return $val unless ref $val;
	}
	return $self->_croak("Can't deflate $col: $val is not a $a_class")
		unless UNIVERSAL::isa($val, $a_class);
	return $val->id if UNIVERSAL::isa($val => 'Class::DBI');
	return "$val";
}

#----------------------------------------------------------------------
# SEARCH
#----------------------------------------------------------------------

sub retrieve_all { shift->sth_to_objects('RetrieveAll') }

sub retrieve_from_sql {
	my ($class, $sql, @vals) = @_;
	$sql =~ s/^\s*(WHERE)\s*//i;
	return $class->sth_to_objects($class->sql_Retrieve($sql), \@vals);
}

sub add_searcher {
	my ($self, %rels) = @_;
	while (my ($name, $class) = each %rels) {
		$self->_require_class($class);
		$self->_croak("$class is not a valid Searcher")
			unless $class->can('run_search');
		no strict 'refs';
		*{"$self\::$name"} = sub {
			$class->new(@_)->run_search;
		};
	}
}

# This should really be its own Search subclass. But the _do_search
# version has been publicised as the way to do this. We need to
# deprecate this eventually.

sub search_like { shift->_do_search(LIKE => @_) }

sub _do_search {
	my ($class, $type, @args) = @_;
	$class->_require_class('Class::DBI::Search::Basic');
	my $search = Class::DBI::Search::Basic->new($class, @args);
	$search->type($type);
	$search->run_search;
}

#----------------------------------------------------------------------
# CONSTRUCTORS
#----------------------------------------------------------------------

sub add_constructor {
	my ($class, $method, $fragment) = @_;
	return $class->_croak("constructors needs a name") unless $method;
	no strict 'refs';
	my $meth = "$class\::$method";
	return $class->_carp("$method already exists in $class")
		if *$meth{CODE};
	*$meth = sub {
		my $self = shift;
		$self->sth_to_objects($self->sql_Retrieve($fragment), \@_);
	};
}

sub sth_to_objects {
	my ($class, $sth, $args) = @_;
	$class->_croak("sth_to_objects needs a statement handle") unless $sth;
	unless (UNIVERSAL::isa($sth => "DBI::st")) {
		my $meth = "sql_$sth";
		$sth = $class->$meth();
	}
	my (%data, @rows);
	eval {
		$sth->execute(@$args) unless $sth->{Active};
		$sth->bind_columns(\(@data{ @{ $sth->{NAME_lc} } }));
		push @rows, {%data} while $sth->fetch;
	};
	return $class->_croak("$class can't $sth->{Statement}: $@", err => $@)
		if $@;
	return $class->_ids_to_objects(\@rows);
}
*_sth_to_objects = \&sth_to_objects;

sub _my_iterator {
	my $self  = shift;
	my $class = $self->iterator_class;
	$self->_require_class($class);
	return $class;
}

sub _ids_to_objects {
	my ($class, $data) = @_;
	return $#$data + 1 unless defined wantarray;
	return map $class->construct($_), @$data if wantarray;
	return $class->_my_iterator->new($class => $data);
}

#----------------------------------------------------------------------
# SINGLE VALUE SELECTS
#----------------------------------------------------------------------

sub _single_row_select {
	my ($self, $sth, @args) = @_;
	Carp::confess("_single_row_select is deprecated in favour of select_row");
	return $sth->select_row(@args);
}

sub _single_value_select {
	my ($self, $sth, @args) = @_;
	$self->_carp("_single_value_select is deprecated in favour of select_val");
	return $sth->select_val(@args);
}

sub count_all { shift->sql_single("COUNT(*)")->select_val }

sub maximum_value_of {
	my ($class, $col) = @_;
	$class->sql_single("MAX($col)")->select_val;
}

sub minimum_value_of {
	my ($class, $col) = @_;
	$class->sql_single("MIN($col)")->select_val;
}

sub _unique_entries {
	my ($class, %tmp) = shift;
	return grep !$tmp{$_}++, @_;
}

sub _invalid_object_method {
	my ($self, $method) = @_;
	$self->_carp(
		"$method should be called as a class method not an object method");
}

#----------------------------------------------------------------------
# misc stuff
#----------------------------------------------------------------------

sub _extend_class_data {
	my ($class, $struct, $key, $value) = @_;
	my %hash = %{ $class->$struct() || {} };
	$hash{$key} = $value;
	$class->$struct(\%hash);
}

my %required_classes; # { required_class => class_that_last_required_it, ... }

sub _require_class {
	my ($self, $load_class) = @_;
	$required_classes{$load_class} ||= my $for_class = ref($self) || $self;

	# return quickly if class already exists
	no strict 'refs';
	return if exists ${"$load_class\::"}{ISA};
	(my $load_module = $load_class) =~ s!::!/!g;
	return if eval { require "$load_module.pm" };

	# Only ignore "Can't locate" errors for the specific module we're loading
	return if $@ =~ /^Can't locate \Q$load_module\E\.pm /;

	# Other fatal errors (syntax etc) must be reported (as per base.pm).
	chomp $@;

	# This error message prefix is especially handy when dealing with
	# classes that are being loaded by other classes recursively.
	# The final message shows the path, e.g.:
	# Foo can't load Bar: Bar can't load Baz: syntax error at line ...
	$self->_croak("$for_class can't load $load_class: $@");
}

sub _check_classes {    # may automatically call from CHECK block in future
	while (my ($load_class, $by_class) = each %required_classes) {
		next if $load_class->isa("Class::DBI");
		$by_class->_croak(
			"Class $load_class used by $by_class has not been loaded");
	}
}

1;

__END__

#line 3185

