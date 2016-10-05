#! /usr/bin/perl

my $frame_shift = 0.01;
my $frame_overlap = 0.015;

while (<>) {
  if (m/--frame-length=(\d+)/) {
    $frame_shift = $1 / 1000;
  } 

  if (m/--window-length=(\d+)/) {
    $frame_overlap = $1 / 1000 - $frame_shift;
}

print "$frame_shift $frame_overlap\n";
