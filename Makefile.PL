use inc::Module::Install;

RTx        'RT-Action-NotifyPagerDuty';
license    'gpl_2';
repository 'https://github.com/catalyst-cloud/RT-Extension-Action-NotifyPagerDuty';

requires   'Agent::PagerDuty' => '0.03';

requires_rt '4.4.0';

my ($lp) = ($INC{'RT.pm'} =~ /^(.*)[\\\/]/);
my $lib_path = join( ' ', "$RT::LocalPath/lib", $lp );
my $bin_path = $RT::BinPath || "$RT::BasePath/bin" || "/opt/rt4/bin";

# Straight from perldoc perlvar
use Config;
my $secure_perl_path = $Config{perlpath};
if ($^O ne 'VMS') {
    $secure_perl_path .= $Config{_exe}
        unless $secure_perl_path =~ m/$Config{_exe}$/i;
}

substitute(
    {
        RT_LIB_PATH  => $lib_path,
        RT_BIN_PATH  => $bin_path,
        PERL         => $ENV{PERL} || $secure_perl_path,
    },
    {
        sufix => '.in'
    },
    qw(bin/rt-flush-pagerduty),
);

sign;
WriteAll;
