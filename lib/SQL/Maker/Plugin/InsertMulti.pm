package SQL::Maker::Plugin::InsertMulti;
use strict;
use warnings;
use utf8;

our @EXPORT = qw/insert_multi/;

# for mysql
sub insert_multi {
    # my ($self, $table, $cols, $binds, $opts) = @_;
    # my ($self, $table, $colvals, $opts) = @_;
    my ( $self, $table, @args ) = @_;
    return unless @{$args[0]};

    my (@cols, @bind, @values, $opts);
    my $first_arg = $args[0]->[0];
    my $is_colvals = ( ref $first_arg ) ? 1 : 0;

    if ( $is_colvals ) {
        @cols   = keys %{$first_arg};
        @values = map { [ @$_{@cols} ] } @{$args[0]};
        $opts   = $args[1] || +{};
    }
    else {
        @cols   = @{$args[0]};
        @values = @{$args[1]};
        $opts   = $args[2] || +{};
    }

    my $prefix = $opts->{prefix} || 'INSERT INTO';
    my $quoted_table = $self->_quote($table);
    my @quoted_cols  = map { $self->_quote($_) } @cols;

    my $sql = "$prefix $quoted_table" . $self->new_line;
       $sql .= '(' . join(', ', @quoted_cols) . ')' . $self->new_line . "VALUES ";

    for my $value ( @values ) {
        my @value_stmt;
        for my $val (@$value) {
            if (ref $val eq 'SCALAR') {
                # $val = \'NOW()'
                push @value_stmt, $$val;
            }
            elsif (ref $val eq 'REF' && ref $$val eq 'ARRAY') {
                # $val = \['UNIX_TIMESTAMP(?)', '2011-04-20 00:30:00']
                my ( $stmt, @sub_bind ) = @{$$val};
                push @value_stmt, $stmt;
                push @bind, @sub_bind;
            }
            else {
                # normal values
                push @value_stmt, '?';
                push @bind, $val;
            }
        }
        $sql .= '(' . join(', ', @value_stmt) . '),' . $self->new_line;
    }

    $sql =~ s/,$self->{new_line}$/$self->{new_line}/;

    if ( $self->{driver} eq 'mysql' && exists $opts->{update} ) {
        my @sets = ref $opts->{update} eq 'HASH' ? %{$opts->{update}} : @{$opts->{update}};
        my @update_sets;
        while (my ($col, $val) = splice @sets, 0, 2) {
            my $quoted_col = $self->_quote($col);
            if ( ref $val eq 'SCALAR' ) {
                # $val = \'NOW()'
                push @update_sets, "$quoted_col = " . $$val;
            }
            elsif ( ref $val eq 'REF' && ref $$val eq 'ARRAY' ) {
                # $val = \['UNIX_TIMESTAMP(?)', '2011-04-20 00:30:00']
                my ( $stmt, @sub_bind ) = @{$$val};
                push @update_sets, "$quoted_col = " . $stmt;
                push @bind, @sub_bind;
            }
            else {
                # normal values
                push @update_sets, "$quoted_col = ?";
                push @bind, $val;
            }
        }
        $sql .= "ON DUPLICATE KEY UPDATE " . join(', ', @update_sets) . $self->{new_line};
    }

    $sql =~ s/$self->{new_line}+$//;

    return ($sql, @bind);
}

1;
__END__

=for test_synopsis
my ($table, @rows);

=head1 NAME

SQL::Maker::Plugin::InsertMulti - insert multiple rows at once on MySQL

=head1 SYNOPSIS

    use SQL::Maker;

    SQL::Maker->load_plugin('InsertMulti');

    my $table = 'foo';
    my @rows = ( +{ bar => 'baz', john => 'man' }, +{ bar => 'bee', john => 'row' } );
    my $builder = SQL::Maker->new( driver => 'mysql' );
    my ($sql, @binds);
    ### INSERT INTO `foo` (`bar`, `john`) VALUES (?, ?), (?, ?)
    ( $sql, @binds ) = $builder->insert_multi($table, \@rows);
    ( $sql, @binds ) = $builder->insert_multi($table, [qw/bar john/], [ map { @$_{qw/bar john/} } @rows ]);
    ### INSERT IGNORE `foo` (`bar`, `john`) VALUES (?, ?), (?, ?)
    ( $sql, @binds ) = $builder->insert_multi($table, [qw/bar john/], [ map { @$_{qw/bar john/} } @rows ], +{ prefix => 'INSERT IGNORE' });
    ### INSERT INTO `foo` (`bar`. `john`) VALUES (?, ?), (?, ?) ON DUPLICATE KEY UPDATE `bar` => ?
    ( $sql, @binds ) = $builder->insert_multi($table, \@rows, +{ update => +{ bar => 'updated' } });
    ( $sql, @binds ) = $builder->insert_multi($table, [qw/bar john/], [ map { @$_{qw/bar john/} } @rows ], +{ update => +{ bar => 'updated' } });

=head1 DESCRIPTION

This is a plugin to generate MySQL's INSERT-multi statement.
