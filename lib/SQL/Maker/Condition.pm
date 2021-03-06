package SQL::Maker::Condition;
use strict;
use warnings;
use utf8;
use SQL::Maker::Util;
use overload
    '&' => sub { $_[0]->compose_and($_[1]) },
    '|' => sub { $_[0]->compose_or($_[1]) },
    fallback => 1;

sub _quote {
    my ($self, $label) = @_;

    return $$label if ref $label;
    SQL::Maker::Util::quote_identifier($label, $self->{quote_char}, $self->{name_sep})
}

sub new {
    my $class = shift;
    my %args = @_==1 ? %{$_[0]} : @_;
    bless {sql => [], bind => [], %args}, $class;
}

sub _make_term {
    my ($self, $col, $val) = @_;

    if ( ref($val) eq 'ARRAY' ) {
        # make_term(foo => {-and => [1,2,3]}) => (foo = 1) AND (foo = 2) AND (foo = 3)
        if ( ref $val->[0] or ( ( $val->[0] || '' ) eq '-and' ) ) {
            my $logic  = 'OR';
            my @values = @$val;
            if ( $val->[0] eq '-and' ) {
                $logic = 'AND';
                shift @values;
            }

            my @bind;
            my @terms;
            for my $v (@values) {
                my ( $term, $bind ) = $self->_make_term( $col, $v );
                push @terms, "($term)";
                push @bind,  @$bind;
            }
            my $term = join " $logic ", @terms;
            return ($term, \@bind);
        }
        else {
            # make_term(foo => [1,2,3]) => foo IN (1,2,3)
            my $term = $self->_quote($col) . " IN (" . substr('?, ' x scalar(@$val), 0, -2) . ')';
            return ($term, $val);
        }
    }
    elsif ( ref($val) eq 'HASH' ) {
        my ( $op, $v ) = ( %{$val} );
        $op = uc($op);
        if ( ( $op eq 'IN' || $op eq 'NOT IN' ) && ref($v) eq 'ARRAY' ) {
            if (@$v == 0) {
                if ($op eq 'IN') {
                    # make_term(foo => +{'IN' => []}) => 0=1
                    return ('0=1', []);
                } else {
                    # make_term(foo => +{'NOT IN' => []}) => 1=1
                    return ('1=1', []);
                }
            } else {
                # make_term(foo => +{ 'IN', [1,2,3] }) => foo IN (1,2,3)
                my $term = $self->_quote($col) . " $op (" . join( ', ', ('?') x scalar @$v ) . ')';
                return ($term, $v);
            }
        }
        elsif ( ( $op eq 'IN' || $op eq 'NOT IN' ) && ref($v) eq 'REF' ) {
            # make_term(foo => +{ 'IN', \['SELECT foo FROM bar'] }) => foo IN (SELECT foo FROM bar)
            my @values = @{$$v};
            my $term = $self->_quote($col) . " $op (" . shift(@values) . ')';
            return ($term, \@values);
        }
        elsif ( ( $op eq 'BETWEEN' ) && ref($v) eq 'ARRAY' ) {
            Carp::croak("USAGE: make_term(foo => {BETWEEN => [\$a, \$b]})") if @$v != 2;
            return ($self->_quote($col) . " BETWEEN ? AND ?", $v);
        }
        else {
            if (ref($v) eq 'SCALAR') {
                # make_term(foo => +{ '<', \"DATE_SUB(NOW(), INTERVAL 3 DAY)"}) => 'foo < DATE_SUB(NOW(), INTERVAL 3 DAY)'
                return ($self->_quote($col) . " $op " . $$v, []);
            }
            else {
                # make_term(foo => +{ '<', 3 }) => foo < 3
                return ($self->_quote($col) . " $op ?", [$v]);
            }
        }
    }
    elsif ( ref($val) eq 'SCALAR' ) {
        # make_term(foo => \"> 3") => foo > 3
        return ($self->_quote($col) . " $$val", []);
    }
    elsif ( ref($val) eq 'REF') {
        my ($query, @v) = @{${$val}};
        return ($self->_quote($col) . " $query", \@v);
    }
    else {
        if (defined $val) {
            # make_term(foo => "3") => foo = 3
            return ($self->_quote($col) . " = ?", [$val]);
        } else {
            # make_term(foo => undef) => foo IS NULL
            return ($self->_quote($col) . " IS NULL", []);
        }
    }
}

sub add {
    my ( $self, $col, $val ) = @_;

    my ( $term, $bind ) = $self->_make_term( $col, $val );
    push @{ $self->{sql} }, "($term)";
    push @{ $self->{bind} },  @$bind;

    return $self; # for influent interface
}

sub compose_and {
    my ($self, $other) = @_;

    return SQL::Maker::Condition->new(
        sql => ['(' . $self->as_sql() . ') AND (' . $other->as_sql() . ')'],
        bind => [@{$self->{bind}}, @{$other->{bind}}],
    );
}

sub compose_or {
    my ($self, $other) = @_;

    return SQL::Maker::Condition->new(
        sql => ['(' . $self->as_sql() . ') OR (' . $other->as_sql() . ')'],
        bind => [@{$self->{bind}}, @{$other->{bind}}],
    );
}

sub as_sql {
    my ($self) = @_;
    return join(' AND ', @{$self->{sql}});
}

sub bind {
    my $self = shift;
    return wantarray ? @{$self->{bind}} : $self->{bind};
}

1;
__END__

=for test_synopsis
my ($sql, @bind);

=head1 NAME

SQL::Maker::Condition - condition object for SQL::Maker

=head1 SYNOPSIS

    my $condition = SQL::Maker::Condition->new(
        name_sep   => '.',
        quote_char => '`',
    );
    $condition->add('foo_id' => 3);
    $condition->add('bar_id' => 4);
    $sql = $condition->as_sql(); # (`foo_id`=?) AND (`bar_id`=?)
    @bind = $condition->bind();  # (3, 4)

    # composite and
    my $other = SQL::Maker::Condition->new(
        name_sep => '.',
        quote_char => '`',
    );
    $other->add('name' => 'john');
    my $comp_and = $condition & $other;
    $sql = $comp_and->as_sql(); # ((`foo_id`=?) AND (`bar_id`=?)) AND (`name`=?)
    @bind = $comp_and->bind();  # (3, 4, 'john')

    # composite or
    my $comp_or = $condition | $other;
    $sql = $comp_and->as_sql(); # ((`foo_id`=?) AND (`bar_id`=?)) OR (`name`=?)
    @bind = $comp_and->bind();  # (3, 4, 'john')


=head1 CONDITION CHEAT SHEET

Here is a cheat sheet for conditions.

    IN:        ['foo','bar']
    OUT QUERY: '`foo` = ?'
    OUT BIND:  ('bar')

    IN:        ['foo',['bar','baz']]
    OUT QUERY: '`foo` IN (?, ?)'
    OUT BIND:  ('bar','baz')

    IN:        ['foo',{'IN' => ['bar','baz']}]
    OUT QUERY: '`foo` IN (?, ?)'
    OUT BIND:  ('bar','baz')

    IN:        ['foo',{'not IN' => ['bar','baz']}]
    OUT QUERY: '`foo` NOT IN (?, ?)'
    OUT BIND:  ('bar','baz')

    IN:        ['foo',{'!=' => 'bar'}]
    OUT QUERY: '`foo` != ?'
    OUT BIND:  ('bar')

    IN:        ['foo',\'IS NOT NULL']
    OUT QUERY: '`foo` IS NOT NULL'
    OUT BIND:  ()

    IN:        ['foo',{'between' => ['1','2']}]
    OUT QUERY: '`foo` BETWEEN ? AND ?'
    OUT BIND:  ('1','2')

    IN:        ['foo',{'like' => 'xaic%'}]
    OUT QUERY: '`foo` LIKE ?'
    OUT BIND:  ('xaic%')

    IN:        ['foo',[{'>' => 'bar'},{'<' => 'baz'}]]
    OUT QUERY: '(`foo` > ?) OR (`foo` < ?)'
    OUT BIND:  ('bar','baz')

    IN:        ['foo',['-and',{'>' => 'bar'},{'<' => 'baz'}]]
    OUT QUERY: '(`foo` > ?) AND (`foo` < ?)'
    OUT BIND:  ('bar','baz')

    IN:        ['foo',['-and','foo','bar','baz']]
    OUT QUERY: '(`foo` = ?) AND (`foo` = ?) AND (`foo` = ?)'
    OUT BIND:  ('foo','bar','baz')

    IN:        ['foo_id',\['IN (SELECT foo_id FROM bar WHERE t=?)',44]]
    OUT QUERY: '`foo_id` IN (SELECT foo_id FROM bar WHERE t=?)'
    OUT BIND:  ('44')

    IN:        ['foo_id', {IN => \['SELECT foo_id FROM bar WHERE t=?',44]}]
    OUT QUERY: '`foo_id` IN (SELECT foo_id FROM bar WHERE t=?)'
    OUT BIND:  ('44')

    IN:        ['foo_id',\['MATCH (col1, col2) AGAINST (?)','apples']]
    OUT QUERY: '`foo_id` MATCH (col1, col2) AGAINST (?)'
    OUT BIND:  ('apples')

    IN:        ['foo_id',undef]
    OUT QUERY: '`foo_id` IS NULL'
    OUT BIND:  ()

    IN:        ['foo_id',{'IN' => []}]
    OUT QUERY: '0=1'
    OUT BIND:  ()

    IN:        ['foo_id',{'NOT IN' => []}]
    OUT QUERY: '1=1'
    OUT BIND:  ()

    IN:        ['foo_id', sql_type(\3, SQL_INTEGER)]
    OUT QUERY: '`foo_id` = ?'
    OUT BIND:  sql_type(\3, SQL_INTEGER)

    IN:        ['created_on', { '>', \'DATE_SUB(NOW(), INTERVAL 1 DAY)' }]
    OUT QUERY: '`created_on` > DATE_SUB(NOW(), INTERVAL 1 DAY)'
    OUT BIND:  

=head1 SEE ALSO

L<SQL::Maker>

