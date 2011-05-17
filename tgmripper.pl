#!/usr/bin/perl

############################################################################
#    T G M R I P P E R                                                     #
#    The Grim Mail Ripper                                                  #
#    v0.1b                                                                 #
#                                                                          #
#    Copyright (C) 2007 by Boyan Tabakov                                   #
#    blade.alslayer@gmail.com                                              #
#                                                                          #
#    This program is free software; you can redistribute it and/or modify  #
#    it under the terms of the GNU General Public License as published by  #
#    the Free Software Foundation; either version 2 of the License, or     #
#    (at your option) any later version.                                   #
#                                                                          #
#    This program is distributed in the hope that it will be useful,       #
#    but WITHOUT ANY WARRANTY; without even the implied warranty of        #
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         #
#    GNU General Public License for more details.                          #
#                                                                          #
#    You should have received a copy of the GNU General Public License     #
#    along with this program; if not, write to the                         #
#    Free Software Foundation, Inc.,                                       #
#    59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.             #
############################################################################

use strict;;
use warnings;

our $version = '0.1b';

use MIME::Parser;
use MIME::Entity;
use Getopt::Long qw/:config bundling/;
use File::Temp;
# use Digest::MD5 qw/md5_hex/;

sub usage();
sub get_args();
sub read_cfg();
sub create_cfg();
sub process_cfg();
sub grim_error($);
sub create_dir($);
sub process_input();
sub strip_attachments($$);
sub save_attachment($);
sub cleanup($);
sub main();

our $config_file = $ENV{'HOME'}.'/.tgmripperrc';

our %cfg = (
		'backup' => 0,
		'backup-dir' => '~/.tgmripper/backup',
		'tmp-dir' => '/tmp',
		'ignore-errors' => 0,
		'extensions' => '',
		'all' => 0,
		'save' => 1,
		'save-dir' => '~/.tgmripper/save',
		'force-pgp' => 0,
	);

our %yesno = ('yes' => 1, 'no' => 0);

our @flags = (qw/backup ignore-errors all save force-pgp/);
our @dirs = (qw/backup-dir tmp-dir save-dir/);
our @others = (qw/extensions/);

our $top_mail_header;
our $parser;

sub usage(){
	my $opt = shift;
	print "Unexpected argument '$opt'\n\n" if $opt;
	print "The Grim Mail Ripper v$version\n\n",
	"Expects e-mail message on standard input.\n",
	#"Below words in '[]' denote optional argument and words in '<>' denote mandatory arguments.\n",
	"Mandatory arguments for long options are mandatory for short options too.\n\n",
	"Usage: tgmripper [options]\n",
	"  -e,     --extensions=<list>    Comma separated list of file extensions. Attachments with these\n",
	"                                 extensions only will be stripped. Provide '*' (mind shell escaping!)\n",
	"                                 to indicate that all attachments should be stripped.\n",
	"  -A,     --all                  Same as --extensions='*'.\n",
	"  -F,     --force-pgp            Force processing of PGP signed or encrypted parts that are normally\n",
	"                                 skipped.\n",
	"  -s,     --save                 Save stripped attachments.\n",
	"  -d,     --save-dir=<dir>       Directory to save stripped attachments (default ~/.tgmripper/save).\n",
	"  -b,     --backup               Save a backup of the original mail.\n",
	"  -D,     --backup-dir=<dir>     Directory to store backup (default  ~/.tgmripper/backup).\n",
	"  -I,     --ignore-errors        Attempt to ignore parsing errors. Could result in loss of data!\n",
	"                                 Implies --backup! Use tgmripper --ignore-errors --no-backup to\n",
	"                                 override backup. Note that ordering of these options matters.\n",
	"                                 Use this only as last resort, if you want to try and see what\n",
	"                                 will happen.\n",
	"  -t,     --tmp-dir=<dir>        Directory to store temporary files (default /tmp).\n",
	"  -h, -?, --help                 Print this message.\n",
	"\nYou can negate flags by adding 'no' before the flag name - e.g. --nobackup or --no-backup.\n",
	"You can specify any of the long named options (without the leading '--') in the configuration\n",
	"file ~/.tgmripperrc. This file will be created, using the default values when the programme is\n",
	"started for the first time. If ignore-errors is found in the configuration file it implies 'backup=yes'\n",
	"unless 'backup=no' is explicitly set there too.\n";
}

sub grim_error($){
	my $msg = shift;
	cleanup($parser) if $parser;
	die "tgmripper error: $msg";
}

sub get_args(){
	my %args;
	
	my $ok = GetOptions(\%args,
				'backup|b!',
				'backup-directory|D=s',
				'tmp-dir|t=s',
				'ignore-errors|I!' => sub {
						my (undef, $val) = @_;
						if ($val){
							$args{'backup'} = 1;
							$args{'ignore-errors'} = 1;
						}else{
							$args{'ignore-errors'} = 0;
						}
				},
				'extensions|e=s',
				'all|A!',
				'save|s!',
				'save-dir|d=s',
				'force-pgp|F!',
				'help|h|?!',
				'<>' => \&usage,
				);
	
	usage() and exit 0 if $args{'help'};
	print "\n" and usage() and exit 1 unless $ok;
	
	foreach(keys %args){
		$cfg{$_} = $args{$_};
	}
}

sub process_cfg(){
# 	grim_error("For safety reasons ignoring errors works only with backup enabled! See tgmripper --help.\n")
# 		if ($cfg{'ignore-errors'} && !$cfg{'backup'});
	foreach (@dirs){
		# force list context
		($cfg{$_}) = glob $cfg{$_};
	}
	$cfg{'extensions'} =~ s/\s//g;
	$cfg{'extensions'} = [grep {$_ eq '*' and $cfg{'all'} = 1 ; $_ =~ /^\w+$/} split /,/, $cfg{'extensions'}];
	# What should I do with this user input?
	# TODO: Maybe limit to alphanumerics and add option to filter on body size?
}

sub read_cfg(){
	my ($opt, $val, %cfg);
	my $flags = join '|', @main::flags;
	my $opts = join '|', @main::dirs, @main::others;
	
	open IN, '<', $config_file or grim_error("Could not open config file $config_file!\n");
	while (<IN>){
		# skip commented lines
		/(^\s*#)|(^$)/ && next;
		# skip commented trailing parts of lines
		/^(.*?[^\\])#/ && ($_ = $1);
		# remove the escaping backslash for # signs that are not comments
		s/\\#/#/g;
		SWITCH:{
			/^\s*($flags)=(.*)/i && do{
				($opt, $val) = ($1, $2);
				$val =~ /^(yes|no|1|0)$/i or grim_error("Variable 'backup' in configuration file has illegal value '$val'! Must be 'yes' or 'no'.\n");
				$cfg{$opt} = $yesno{lc $1};
				last SWITCH;
			};
			/^\s*($opts)=(.*)/i && do{
				#($opt, $val) = ($1, $2);
				$cfg{$1} = $2;
				last SWITCH;
			};
			# seems like good option but it is not
			/^(\w*)=(.*)/ && do{
				grim_error("Found unknown option '$1' in configuration file!\n");
			};
			# anything else is bad
			/^(.*)/ && do{
				grim_error("Irregular syntax in configuration file: '$1'!\n");
			};
		}
	}
	$cfg{'backup'} = 1 if ($cfg{'ignore-errors'} && !exists $cfg{'backup'});
	foreach(keys %cfg){
		$main::cfg{$_} = $cfg{$_};
	}
	close IN or grim_error("Could not close file handle of read configuration file!\n");
}

sub create_cfg(){
	my $opt;
	
	open OUT, ">", $config_file or grim_error("Could not create configuration file!\n");
	print OUT "# Configuration file for tgmripper\n",
	"#\n# Syntax: <option name>=<value>\n#\n",
	"# See tgmripper --help for details on the available options.\n",
	"# Empty lines are skipped.\n",
	"# Any charactes after a hash sign (#) in a line are ignored. Type '\\#'\n",
	"# to use '#' in a value.\n\n";
	foreach $opt (sort keys %cfg){
		if (grep {$opt eq $_} @flags){
			print OUT "# $opt=".($cfg{$opt} ? 'yes' : 'no')."\n";
		}else{
			print OUT "# $opt=$cfg{$opt}\n";
		}
	}
	close OUT or grim_error("Could not close file handle of written configuration file!\n")
}

sub cleanup($){
	my $parser = shift;
	$parser->filer->purgeable($parser->output_under());
	$parser->filer->purge();
}

sub create_dir($){
	my $target = shift;
	-d $target or do{
		
		my @dirs = split /\//, $target;
		my $path = '/';
		my $ok = 1;
		
		foreach(@dirs){
			next if not $_;
			-d "$path$_" or $ok = mkdir $path.$_;
			grim_error("Could not create directory $path$_!\n$!") unless $ok;
			$path .= $_.'/';
		}
	};
}

sub process_input(){
	my $parser = new MIME::Parser or grim_error("Could not create parser!\n");
	my $mail;
	
	$parser->output_under($cfg{'tmp-dir'});
	$parser->ignore_errors($cfg{'ignore-errors'});
	
	if ($cfg{'backup'}){
		# Duplicating the input via pieps seems to work
		# a lot faster than to read the entire file in memory.
		# So, we spawn a child to pipe to us and to save backup.
		pipe READ, WRITE or grim_error("Could not create pipe!\n");
		my $proc = fork();
		if ($proc){
			# parent
			close WRITE or grim_error("Could not close parent's WRITE pipe!\n");
			
			eval {$mail = $parser->parse(\*READ)};
			
			close READ or grim_error("Could not close parent's READ pipe!\n");
		}elsif ($proc == 0){
			# child
			close READ or grim_error("Could not close child's READ pipe!\n");
			
			create_dir($cfg{'backup-dir'});
			
			my $out = new File::Temp('TEMPLATE' => 'tgmripperXXXXXX',
				'SUFFIX' => '.bak', 'UNLINK' => 0, 'DIR' => $cfg{'backup-dir'})
 				or grim_error("Could not create backup file!\n");
				
 				while (<>){
 					print $out $_ or grim_error("Can't write to backup file!\n");
 					print WRITE $_ or grim_error("Can't write to pipe!\n");
 				}
				
 				close WRITE or grim_error("Could not close child's WRITE pipe!\n");
 				exit;
		}else{
			# failed
			grim_error("Could not fork!\n");
		}
	}else{
		eval {$mail = $parser->parse(\*STDIN)};
	}
	
	if (!$cfg{'ignore-errors'} && $parser->last_error()){
		print STDERR $parser->results->msgs(), "\n";
		cleanup($parser);
		grim_error("Parsing message failed!\n");
	}
	
	# parsing ok, procede
	# TODO: Is a single part mail possible to hold attachment as its only part?
	
	cleanup($parser) and return if $mail->parts() == 0;
	
	$main::parser = $parser;
	$top_mail_header = $mail->head();
	create_dir($cfg{'save-dir'}) if $cfg{'save'};
	strip_attachments($mail, undef);
	
	# output
	$mail->print(\*STDOUT) or grim_error("Could not write to stdout!\n");
	
	cleanup($parser);
}

sub strip_attachments($$){
	my ($mail, $parent) = @_;
	my @parts = $mail->parts();
	
	# Skip multipart/encrypted and multipart/signed messages
	# TODO: Handle signed messages? Allow breaking of signature or resigning if possible?
	
	$cfg{'force-pgp'} or return
		if $mail->head->mime_type() =~ /multipart\/encrypted|multipart\/signed/;
	
	if (@parts == 0){
		my $filename = $mail->head->recommended_filename();
		
		if ($filename){
		# Seems like an attachment - should we process?
			my $extensions = join '|', @{$cfg{'extensions'}};
			$cfg{'all'} or ($extensions and $filename =~ /.($extensions)$/) or return;
			# TODO: Size filtering should be checked too.
			
			save_attachment($mail) if $cfg{'save'};
			
			# Do it the long and easy way...
# 			my $new = MIME::Entity->build('Type' => "text/plain",
# 				'Encoding' => "base64",
# 				'Data' => ["*** Attachment '$filename' stripped by tgmripper! ***"],
# 				'X-Mailer' => "tgmripper using MIME::Tools v$MIME::Tools::VERSION",
# 				'Foo' => 'tgmripper-stripped-attachment',
# 				);
# 			$parent->parts([map {($_ == $mail) ? $new : $_} $parent->parts()]);
			# ... or do it the short and harder way...
			my $new_head = new MIME::Head();
			$new_head->mime_attr('content-type' => 'text/plain');
			$new_head->mime_attr('content-type.charset' => 'utf8');
			$new_head->mime_attr('content-transfer-encoding' => 'base64');
			$new_head->mime_attr('content-disposition' => 'inline');
			$mail->head($new_head);
			
			my $IO = $mail->bodyhandle->open('w') or grim_error("Could not open bodyhandle for writing!\n");
			$IO->print("*** Attachment '$filename' stripped by tgmripper! ***") or grim_error("Could not write to body!\n");
			$IO->close() or grim_error("Could not close bodyhandle!\n");
		}else{
		# TODO: We don't have filename. can it still be attachment?
		}
		return;
	}
	
	foreach(@parts){
		strip_attachments($_, $mail);
	}
	
}

sub save_attachment($){
	my $filename;
	my $mail = shift;
	my $name = $mail->head->recommended_filename();
	my $from = $top_mail_header->get('From');
	# At some point I thought of generating the id with
	# an md5 sum of the headers. The Message-Id header
	# now seems as the better idea, though the md5 sum looks better.
	# my $id = md5_hex($top_mail_header->as_string());
	my $id = $top_mail_header->get('Message-Id');
	
	chomp $from;
	chomp $id;
	
	# This is not for vlidating the address. It's just to extract
	# what looks like the address from the From field.
	$from =~ /(\w+((\.|-|\+)\w+)*)@(\w+((\.|-|\+)\w+)+)/;
	$from = "$1".'@'."$4";
	
	create_dir($cfg{'save-dir'}.'/'.$from);
	$filename = $cfg{'save-dir'}.'/'.$from.'/'.$id.'-'.$name;
	
	open OUT, ">", $filename or grim_error("Could open file $filename to save attachment!\n");
	$mail->bodyhandle->print(\*OUT) or grim_error("Could not write to file $filename!\n");
	close OUT or grim_error("Could not close file handle of saved attachment!\n");
}

sub main(){	
	-f $config_file ? read_cfg() : create_cfg();
	get_args();
	process_cfg();
	process_input();
}

main::main();
