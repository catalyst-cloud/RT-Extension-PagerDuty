use inc::Module::Install;

RTx     'RT-Action-NotifyPagerDuty';
license 'gpl_2';
repository 'https://github.com/catalyst-cloud/RT-Extension-Action-NotifyPagerDuty';

requires_rt '4.4.0';

sign;
WriteAll;
