package SQL::Translator::Producer::ClassDBI;

# -------------------------------------------------------------------
# $Id: ClassDBI.pm,v 1.34 2003-08-20 13:50:46 dlc Exp $
# -------------------------------------------------------------------
# Copyright (C) 2003 Allen Day <allenday@ucla.edu>,
#                    Ying Zhang <zyolive@yahoo.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation; version 2.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
# 02111-1307  USA
# -------------------------------------------------------------------

use strict;
use vars qw[ $VERSION $DEBUG ];
$VERSION = sprintf "%d.%02d", q$Revision: 1.34 $ =~ /(\d+)\.(\d+)/;
$DEBUG   = 1 unless defined $DEBUG;

use SQL::Translator::Schema::Constants;
use SQL::Translator::Utils qw(header_comment);
use Data::Dumper;

my %CDBI_auto_pkgs = (
    MySQL      => 'mysql',
    PostgreSQL => 'Pg',
    Oracle     => 'Oracle',
);

# -------------------------------------------------------------------
sub produce {
    my $t             = shift;
	my $create        = undef;
    local $DEBUG      = $t->debug;
    my $no_comments   = $t->no_comments;
    my $schema        = $t->schema;
    my $args          = $t->producer_args;
    my $db_user       = $args->{'db_user'} || '';
    my $db_pass       = $args->{'db_pass'} || '';
    my $main_pkg_name = $t->format_package_name('DBI');
    my $header        = header_comment(__PACKAGE__, "# ");
    my $parser_type   = ( split /::/, $t->parser_type )[-1];
    my $from          = $CDBI_auto_pkgs{ $parser_type } || '';
    my $dsn           = $args->{'dsn'} || sprintf( 'dbi:%s:_',
                            $CDBI_auto_pkgs{ $parser_type }
                            ? $CDBI_auto_pkgs{ $parser_type } : $parser_type
                        );
    my $sep           = '# ' . '-' x 67;

    #
    # Identify "link tables" (have only PK and FK fields).
    #
    my %linkable;
    my %linktable;
    foreach my $table ( $schema->get_tables ) {
        my $is_link = 1;
        foreach my $field ( $table->get_fields ) {
            unless ( $field->is_primary_key or $field->is_foreign_key ) {
                $is_link = 0; 
                last;
            }
        }

        next unless $is_link;
      
        foreach my $left ( $table->get_fields ) {
            next unless $left->is_foreign_key;
            my $lfk           = $left->foreign_key_reference or next;
            my $lr_table      = $schema->get_table( $lfk->reference_table )
                                 or next;
            my $lr_field_name = ($lfk->reference_fields)[0];
            my $lr_field      = $lr_table->get_field($lr_field_name);
            next unless $lr_field->is_primary_key;

            foreach my $right ( $table->get_fields ) {
                next if $left->name eq $right->name;
        
                my $rfk      = $right->foreign_key_reference or next;
                my $rr_table = $schema->get_table( $rfk->reference_table )
                               or next;
                my $rr_field_name = ($rfk->reference_fields)[0];
                my $rr_field      = $rr_table->get_field($rr_field_name);
                next unless $rr_field->is_primary_key;
        
                $linkable{ $lr_table->name }{ $rr_table->name } = $table;
                $linkable{ $rr_table->name }{ $lr_table->name } = $table;
                $linktable{ $table->name } = $table;
            }
        }
    }

    #
    # Iterate over all tables
    #
    my ( %packages, $order );
    for my $table ( $schema->get_tables ) {
        my $table_name = $table->name or next;

        my $table_pkg_name = $t->format_package_name($table_name);
        $packages{ $table_pkg_name } = {
            order     => ++$order,
            pkg_name  => $table_pkg_name,
            base      => $main_pkg_name,
            table     => $table_name,
        };

        #
        # Primary key may have a differenct accessor method name
        #
        if ( my $pk_xform = $t->format_pk_name ) {
            if ( my $constraint = $table->primary_key ) {
                my $field          = ($constraint->fields)[0];
                my $pk_name        = $pk_xform->($table_pkg_name, $field);

				$packages{ $table_pkg_name }{'_columns_primary'} = $field;

                $packages{ $table_pkg_name }{'pk_accessor'} = 
                    "#\n# Primary key accessor\n#\n".
                    "sub $pk_name {\n    shift->$field\n}\n\n"
                ;
            }
        }

        my $is_data = 0;
        foreach my $field ( $table->get_fields ) {
		  if ( !$field->is_foreign_key and !$field->is_primary_key ) {
			push @{ $packages{ $table_pkg_name }{'_columns_essential'} }, $field->name;
			$is_data++;
		  } elsif ( !$field->is_primary_key ) {
			push @{ $packages{ $table_pkg_name }{'_columns_others'} }, $field->name;
		  }
		}

		my %linked;
		if ( $is_data ) {
		  foreach my $link ( keys %{ $linkable{ $table_name } } ) {
			my $linkmethodname;

			if ( my $fk_xform = $t->format_fk_name ) {
			  # ADD CALLBACK FOR PLURALIZATION MANGLING HERE
			  $linkmethodname = $fk_xform->($linkable{$table_name}{$link}->name,
											($schema->get_table($link)->primary_key->fields)[0]).'s';
			} else {
			  # ADD CALLBACK FOR PLURALIZATION MANGLING HERE
			  $linkmethodname = $linkable{$table_name}{$link}->name.'_'.
				($schema->get_table($link)->primary_key->fields)[0].'s';
			}

			my @rk_fields = ();
			my @lk_fields = ();
			foreach my $field ($linkable{$table_name}{$link}->get_fields) {
			  next unless $field->is_foreign_key;

			  next unless(
						  $field->foreign_key_reference->reference_table eq $table_name
						  ||
						  $field->foreign_key_reference->reference_table eq $link
						 );
			  push @lk_fields, ($field->foreign_key_reference->reference_fields)[0]
				if $field->foreign_key_reference->reference_table eq $link;
			  push @rk_fields, $field->name
				if $field->foreign_key_reference->reference_table eq $table_name;
			}

			#if one possible traversal via link table
			if (scalar(@rk_fields) == 1 and scalar(@lk_fields) == 1) {
			  foreach my $rk_field (@rk_fields) {
				push @{ $packages{ $table_pkg_name }{'has_many'}{ $link } },
				  "sub ".$linkmethodname." { my \$self = shift; ".
					"return map \$_->".
					  ($schema->get_table($link)->primary_key->fields)[0].
						", \$self->".$linkable{$table_name}{$link}->name.
						  "_".$rk_field." }\n\n";
			  }
			  #else there is more than one way to traverse it.  ack!
			  #let's treat these types of link tables as a many-to-one (easier)
			  #
			  #NOTE: we need to rethink the link method name, as the cardinality
			  #has shifted on us.
			} elsif (scalar(@rk_fields) == 1) {
			  foreach my $rk_field (@rk_fields) {
				# ADD CALLBACK FOR PLURALIZATION MANGLING HERE
				push @{ $packages{ $table_pkg_name }{'has_many'}{ $link } },
				  "sub " . $linkable{$table_name}{$link}->name .
					"s { my \$self = shift; return \$self->" .
					  $linkable{$table_name}{$link}->name . "_" .
						$rk_field . "(\@_) }\n\n";
			  }
			} elsif (scalar(@lk_fields) == 1) {
			  #these will be taken care of on the other end...
			} else {
			  #many many many.  need multiple iterations here, data structure revision
			  #to handle N FK sources.  This code has not been tested and likely doesn't
			  #work here
			  foreach my $rk_field (@rk_fields) {
				# ADD CALLBACK FOR PLURALIZATION MANGLING HERE
				push @{ $packages{ $table_pkg_name }{'has_many'}{ $link } },
				  "sub " . $linkable{$table_name}{$link}->name . "_" . $rk_field .
					"s { my \$self = shift; return \$self->" .
					  $linkable{$table_name}{$link}->name . "_" .
						$rk_field . "(\@_) }\n\n";
			  }
			}
		  }
        }


        #
        # Use foreign keys to set up "has_a/has_many" relationships.
        #
        foreach my $field ( $table->get_fields ) {
            if ( $field->is_foreign_key ) {
                my $table_name = $table->name;
                my $field_name = $field->name;
                my $fk_method  = $t->format_fk_name($table_name, $field_name);
                my $fk         = $field->foreign_key_reference;
                my $ref_table  = $fk->reference_table;
                my $ref_pkg    = $t->format_package_name($ref_table);
                my $ref_field  = ($fk->reference_fields)[0];

                push @{ $packages{ $table_pkg_name }{'has_a'} },
                    "$table_pkg_name->has_a(\n".
                    "    $field_name => '$ref_pkg'\n);\n\n".
                    "sub $fk_method {\n".
                    "    return shift->$field_name\n}\n\n"
                ;

                #
                # If this table "has a" to the other, then it follows 
                # that the other table "has many" of this one, right?
                #
				# No... there is the possibility of 1-1 cardinality

				#if there weren't M-M relationships via the has_many
				#being set up here, create nice pluralized method alias
				#rather for user as alt. to ugly tablename_fieldname name
				if(! $packages{ $ref_pkg }{ 'has_many' }{ $table_name } ){
				  # ADD CALLBACK FOR PLURALIZATION MANGLING HERE
				  push @{ $packages{ $ref_pkg }{'has_many'}{ $table_name } },
					"sub ${table_name}s {\n    return shift->$table_name\_$field_name\n}\n\n";

				#else ugly
				} else {
				}

				push @{ $packages{ $ref_pkg }{'has_many'}{ $table_name } },
				  "$ref_pkg->has_many(\n    '${table_name}_${field_name}', ".
				  "'$table_pkg_name' => '$field_name'\n);\n\n";

            }
		}
	}

    #
    # Now build up text of package.
    #
    my $base_pkg = sprintf( 'Class::DBI%s', $from ? "::$from" : '' );
    $create .= join("\n",
      "package $main_pkg_name;\n",
      $header,
      "use strict;",
      "use base '$base_pkg';\n",
      "$main_pkg_name->set_db('Main', '$dsn', '$db_user', '$db_pass');\n\n",
    ); 

    for my $pkg_name ( 
        sort { $packages{ $a }{'order'} <=> $packages{ $b }{'order'} }
        keys %packages
    ) {
        my $pkg = $packages{ $pkg_name };

        $create .= join("\n",
            $sep,
            "package ".$pkg->{'pkg_name'}.";",
            "use base '".$pkg->{'base'}."';",
            "use Class::DBI::Pager;\n\n",
        );    

#        if ( $from ) {
#            $create .= 
#                $pkg->{'pkg_name'}."->set_up_table('".$pkg->{'table'}."');\n\n";
#        }
#        else {
#            my $table       = $schema->get_table( $pkg->{'table'} );
#            my @field_names = map { $_->name } $table->get_fields;
#
#            $create .= join("\n",
#                $pkg_name."->table('".$pkg->{'table'}."');\n",
#                $pkg_name."->columns(All => qw/".
#                join(' ', @field_names)."/);\n\n",
#            );
#        }


		#the approach here is to do lazy loading on the expensive columns
		#(expensive defined as those columns which require construction of a referenced object)
		#fields which are strictly data (ie, not references) are treated as essential b/c they
		#don't require much time to set up.

		$create .= $pkg_name."->table('".$pkg->{'table'}."');\n";

		#set up primary key field
		if( $pkg->{'_columns_primary'} ) {
		  $create .= $pkg_name."->columns(Primary   => qw/".              $pkg->{'_columns_primary'}      ."/);\n";
		} else {
		  die "Class::DBI isn't going to like that you don't have a primary key field for table ".$pkg->{'table'};
		}

		#set up non-FK fields to be populated at construction
		if( $pkg->{'_columns_essential'} ) {
		  $create .= $pkg_name."->columns(Essential => qw/". join(' ', @{ $pkg->{'_columns_essential'} }) ."/);\n";
		}

		#set up FK fields for lazy loading on request
		if( $pkg->{'_columns_others'} ) {
		  $create .= $pkg_name."->columns(Others    => qw/".    join(' ', @{ $pkg->{'_columns_others'}    }) ."/);\n";
		}

		$create .= "\n";

        if ( my $pk = $pkg->{'pk_accessor'} ) {
            $create .= $pk;
        }

        if ( my @has_a = @{ $pkg->{'has_a'} || [] } ) {
            $create .= $_ for @has_a;
        }

		foreach my $has_many_key (keys %{ $pkg->{'has_many'} }){
		  if ( my @has_many = @{ $pkg->{'has_many'}{ $has_many_key } || [] } ) {
            $create .= $_ for @has_many;
		  }
		}
    }

    $create .= "1;\n";

    return $create;
}

1;

# -------------------------------------------------------------------

=pod

=head1 NAME

SQL::Translator::Producer::ClassDBI - create Class::DBI classes from schema

=head1 SYNOPSIS

Use this producer as you would any other from SQL::Translator.  See
L<SQL::Translator> for details.

This package utilizes SQL::Translator's formatting methods
format_package_name(), format_pk_name(), format_fk_name(), and
format_table_name() as it creates classes, one per table in the schema
provided.  An additional base class is also created for database connectivity
configuration.  See L<Class::DBI> for details on how this works.

=head1 AUTHORS

Allen Day E<lt>allenday@ucla.eduE<gt>
Ying Zhang E<lt>zyolive@yahoo.comE<gt>,
Ken Y. Clark E<lt>kclark@cpan.orgE<gt>.
