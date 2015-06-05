use strict;
use warnings;

# this test is very similar to what is generated by Dist::Zilla::Plugin::Test::CheckBreaks

use Test::More;

eval {
    require CPAN::Meta;
    require CPAN::Meta::Requirements;
    CPAN::Meta::Requirements->VERSION(2.120920);
    require Module::Metadata;
    1
} or plan skip_all => 'breakage test requires CPAN::Meta, CPAN::Meta::Requirements and Module::Metadata';

my $metafile = -e 'MYMETA.json' ? 'MYMETA.json'
             : -e 'META.json'   ? 'META.json'
             :                    undef;

unless ($metafile) {
  plan skip_all => "can't check breakages without some META file";
}

my $breaks = CPAN::Meta->load_file($metafile)->custom('x_breaks');
my $reqs = CPAN::Meta::Requirements->new;
$reqs->add_string_requirement($_, $breaks->{$_}) foreach keys %$breaks;

my $result = check_breaks($reqs);
if (my @breaks = grep { defined $result->{$_} } keys %$result)
{
    diag 'You have the following modules installed, which are not compatible with the latest Test::More:';
    diag "$result->{$_}" for sort @breaks;
    diag "\n", 'You should now update these modules!';
}

pass 'conflicting modules checked';

# this is an inlined simplification of CPAN::Meta::Check.
sub check_breaks {
    my $reqs = shift;
    return +{
        map { $_ => _check_break($reqs, $_) } $reqs->required_modules,
    };
}

sub _check_break {
    my ($reqs, $module) = @_;
    my $metadata = Module::Metadata->new_from_module($module);
    return undef if not defined $metadata;
    my $version = eval { $metadata->version };
    return "Missing version info for module '$module'" if not $version;
    return sprintf 'Installed version (%s) of %s is in range \'%s\'', $version, $module, $reqs->requirements_for_module($module) if $reqs->accepts_module($module, $version);
    return undef;
}

done_testing;
