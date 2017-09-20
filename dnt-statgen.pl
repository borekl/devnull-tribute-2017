#!/usr/bin/env perl

#============================================================================
# /dev/null/nethack Tribute 2017 Statistics Generator
# """""""""""""""""""""""""""""""""""""""""""""""""""
# (c) 2017 Borek Lupomesky
#
# Scoreboard generator for /dev/null/nethack Tribute 2017. Please see README
# for documentation on how this works.
#============================================================================

use strict;
use warnings;
use utf8;

use Getopt::Long;
use JSON;



#============================================================================
#=== definitions ============================================================
#============================================================================

my $lockfile = '/tmp/dnt-statgen.lock';



#============================================================================
#=== global variables =======================================================
#============================================================================

# configuration, parsed from external file

my $cfg;

# array of function references that are called for each xlogfile row

my @row_consumers;

# the complete scoreboard data are held in this variable; this is the data
# that are supplied to Template Toolkit templates for rendering the actual
# web pages; the structure is described in the README.md

my %s;



#============================================================================
#=== stuff to do at startup =================================================
#============================================================================

BEGIN
{
  my $js = new JSON->relaxed(1);
  local $/;

  #--- read configuration file

  open(my $fh, '<', 'dnt.conf') or die 'Failed to open configuration file';
  my $config = <$fh>;
  close($fh);
  $cfg = $js->decode($config);
}



#============================================================================
#=== functions ==============================================================
#============================================================================

#============================================================================
# Split a line along field separator, parse it into hash and return it as
# a hashref.
#============================================================================

sub parse_log
{
  my $l = shift;
  my %l;
  my (@a1, @a2, $a0);

  #--- there are two field separators in use: comma and horizontal tab;
  #--- we use simple heuristics to find out the one that is used for given
  #--- xlogfile row

  @a1 = split(/:/, $l);
  @a2 = split(/\t/, $l);
  $a0 = scalar(@a1) > scalar(@a2) ? \@a1 : \@a2;

  #--- split keys and values

  for my $field (@$a0) {
    my ($key, $val) = split(/=/, $field);
    $l{$key} = $val;
  }

  #--- finish returning hashref

  return \%l
}



#============================================================================
#=== row consumers ==========================================================
#============================================================================

#============================================================================
# Record players' games
#============================================================================

push(@row_consumers, sub
{
  my $xrow = shift;
  my $plr_name = $xrow->{'name'};

  #--- if player sub-tree or the games list do not exist, instantiate it

  if(
    !exists $s{'players'}{'data'}{$plr_name}
    || !exists $s{'players'}{'data'}{$plr_name}{'games'}
  ) {
    $s{'players'}{'data'}{$plr_name}{'games'} = [];
  }

  #--- push new game into the list

  push(@{$s{'players'}{'data'}{$plr_name}{'games'}}, $xrow);

});


#============================================================================
# Display usage summary
#============================================================================

sub help
{
  print "Command-line options:\n";
  print "  --debug       debug mode\n";
  print "\n";
}



#============================================================================
#===================  _  ====================================================
#===  _ __ ___   __ _(_)_ __  ===============================================
#=== | '_ ` _ \ / _` | | '_ \  ==============================================
#=== | | | | | | (_| | | | | | ==============================================
#=== |_| |_| |_|\__,_|_|_| |_| ==============================================
#===                           ==============================================
#============================================================================
#============================================================================

#--- process command-line options

my (
  $cmd_debug
);

if(!GetOptions(
  'debug' => \$cmd_debug,
)) {
  help();
  exit(1);
}

#--- check/create lock file

if(-f $lockfile) {
  print "Lockfile $lockfile exists, exiting.";
  exit(1);
}

open(F, '>', $lockfile) || die "Failed to create lockfile $lockfile";
print F $$, "\n";
close(F);

#--- read the xlogfile

my $cnt = 0;
open(my $xlog, '<', $cfg->{'xlogfile'}) or die "Could not open the xlogfile";
while(my $l = <$xlog>) {
  chomp($l);
  my $xrow = parse_log($l);
  for my $consumer (@row_consumers) {
    $consumer->($xrow);
  }
  $cnt++;
}
close($xlog);

#--- debug: save the compiled scoreboard data as JSON

if($cmd_debug) {
  open(JS, '>', "debug.scoreboard.$$") or die;
  print JS JSON->new->pretty(1)->encode(\%s), "\n";
  close(JS);
}

#--- release lock file

unlink($lockfile);
