#!/usr/bin/env perl
# https://github.com/JonStratton/grpc-reflectionless-information-tester
# Parses a proto file and builds some grpcurl commands.
#################
# TODO:
# Deal with enums. Just make them int32s?
# Default values that is a config, and can default based on package/service/name
#################

use strict;
use warnings;
use Getopt::Std;
use File::Basename;

# Command line params
my %opts = ();
getopts('vp:w:d:g:', \%opts);

my $VERBOSE = exists($opts{'v'}) ? 1 : 0;
my @WORDLISTS = defined($opts{'w'}) ? split(/,\s*/, $opts{'w'}, -1) : [];
my @PROTOFILES = defined($opts{'p'}) ? split(/,\s*/, $opts{'p'}, -1) : [];
my $ADDRESS = $ARGV[0];
my $DEFAULTS_JSON = $opts{'d'};
my $GRPCURL_ARGS = defined($opts{'g'}) ? $opts{'g'} : '';

if (!(@PROTOFILES and $ADDRESS and @WORDLISTS)) {
   print "$0 -w ./wordlist.txt -p ./helloworld.proto localhost:50051\n";
   exit(1);
}

my %TypesToDefaults = (
   'string' => 'a',
   'int32' => 1,
   'bool' => 'true'
);

my %CustomDefaults = (); # User supplied via JSON
my %TypeToWordlist = ();

##########################
# Defaults and wordlists #
##########################

# Populate %CustomDefaults with the field name to default value
if ($DEFAULTS_JSON && -e $DEFAULTS_JSON) {
   use JSON; # libjson-pp-perl
   printf("Reading: %s\n", $DEFAULTS_JSON) if ($VERBOSE);
   open(my $json_h, '<', $DEFAULTS_JSON) or warn(sprintf("Warning, the following file does not exist or is not readable: %s\n", $DEFAULTS_JSON));
   my $json = join('', <$json_h>);
   close($json_h);
   %CustomDefaults = %{decode_json($json)};
}

# Populate %TypeToWordlist with Wordlists. If we just have one, set it to the default (*) and use it for all fields.
foreach my $wordlist (@WORDLISTS) {
   if ($wordlist =~ /(.+)\s*:\s*(.+)/) {
      $TypeToWordlist{$1} = $2;
   } else {
      $TypeToWordlist{'*'} = $wordlist;
   }
}

########
# Main #
########

sub main {
   # $services{$package}{$service}{$rpc}{MessageStuffHere} = Values
   # $messages{$package}{}
   my (%services, %messages);
   foreach my $protofile (@PROTOFILES) {
       parse_proto_file($protofile, \%services, \%messages);
   }

   # Gen test skeleton
   foreach my $package (sort(keys(%services))) {
     foreach my $service (sort(keys(%{$services{$package}}))) {
        foreach my $rpc (sort(keys(%{$services{$package}{$service}}))) {
            my $servicePath = sprintf("%s.%s/%s", $package, $service, $rpc);
            my $request   = $services{$package}{$service}{$rpc}{'request'};
            my $protofile = $services{$package}{$service}{$rpc}{'protofile'};
            my $data_string = params_to_string($request, $messages{$package});
            my $protofile_dir = dirname($protofile);
            my $protofile_base = basename($protofile);

            foreach my $data_test (data_to_tests($data_string)) {
                my $test = ${$data_test}{'test'};
                my $wordlist = ${$data_test}{'wordlist'};
                my $grit_cmd = sprintf("grit_endpoint_protofuzz.pl -w %s -d '%s' -g '%s -import-path %s -proto %s' %s %s", $wordlist, $test, $GRPCURL_ARGS, $protofile_dir, $protofile_base, $ADDRESS, $servicePath);
                printf("%s\n", $grit_cmd);
            }
         }
      }
   }
}

# Converts {"blah1":"_string_","blah2":"_string_"} to {"blah1":"_PAYLOAD_","blah2":"a"} and {"blah1":"a","blah2":"_PAYLOAD_"}
sub data_to_tests {
   my ($in_string) = @_;
   
   my @substItems; # TODO, move this to something returned from params_to_string() rather that parse stuff back out of a string we just created...
   while($in_string =~ /"([^"]+)":"([^]+)"/g) { push(@substItems, {'name'=>$1, 'type'=>$2}) }

   my @tests;
   foreach my $fuzzIndex (0..(scalar(@substItems)-1)) { # Foreach key/value pair from the payload, we want to make a new test for each set
      my $temp_string = $in_string;
      my $pairIndex = 0;
      my $wordlist = '';
      foreach my $pairRef (@substItems) { # Set defaults, unless we are looking at the pair we want to fuzz
         my ($name, $type) = (${$pairRef}{'name'}, ${$pairRef}{'type'});

         my $value = '';
         # If we are on the item to set the PAYLOAD for AND we have a wordlist for that type (or one for all types)
         if ($fuzzIndex == $pairIndex && (defined($TypeToWordlist{$type}) || defined($TypeToWordlist{'*'}))) {
            $value = '_PAYLOAD_';
            $wordlist = defined($TypeToWordlist{$type}) ? $TypeToWordlist{$type} : $TypeToWordlist{'*'};
         } else {
            if (defined($CustomDefaults{$name})) {
               $value = $CustomDefaults{$name};
            } elsif (defined($TypesToDefaults{$type})) {
               $value = $TypesToDefaults{$type};
            } else {
               $value = 1;
            }
         }
         $temp_string =~ s/$type/$value/;
         $pairIndex++;
      }
      push(@tests, {'test' => $temp_string, 'wordlist' => $wordlist}) if ($wordlist);
   }

   return(@tests);
}

# Recursion for nested objects
sub params_to_string {
   my ($message_name, $packMesg_ref) = @_;
   my @params;
   if (defined(${$packMesg_ref}{$message_name})) {
      foreach my $paramSet (@{${$packMesg_ref}{$message_name}}) {
         next unless defined(${$paramSet}{'name'}); # Gaps in numbers in the protofiles
         my $type = ${$paramSet}{'type'};
         # Is type just another object name?

         my $type_string = sprintf("\"%s\"", ${$paramSet}{'type'});
         if (defined(${$packMesg_ref}{$type})) {
            $type_string = params_to_string($type, $packMesg_ref);
         }

         push(@params, sprintf("\"%s\":%s", ${$paramSet}{'name'}, $type_string));
      }
   }
   return(sprintf("{%s}", join(', ', @params)));
}

# All our ugly proto parsing at the bottom so we dont have to see it.
sub parse_proto_file {
   my ($protofile, $services_ref, $messages_ref) = @_;
   my ($package);
   printf("Reading: %s\n", $protofile) if ($VERBOSE);

   if (open(my $protofile_h, '<', $protofile)) {

      my @level;
      while(my $line = <$protofile_h>) {
         chomp($line);

         # Strip out padded whitespace, comments, and empty lines
         $line =~ s/(^\s*)|(\s*$)//;
         $line =~ s/\s*\/\/.*$//;
         $line =~ s/\s*\/\*.*$//;
         next unless ($line);

         # "package helloworld;"
         if ($line =~ /^package\s+(.+);/) {
            $package = $1;
         }

         # "service Greeter {", Get the service name. We are in service.
         if ($line =~ /^service\s+(\w+)\s+{/) {
            push(@level, {'name' => $1, 'type' => 'service'});
         }

         # "rpc SayHelloStreamReply (HelloRequest) returns (stream HelloReply) {}"
         if (($line =~ /^rpc\s+(\w+)\s*\((.+)\)\s+returns\s+\((.+)\)\s*{}/) && @level && $level[-1]{'type'} eq 'service') {
            my ($rpcName, $request, $reply) = ($1, $2, $3);
            my $serviceName = $level[-1]{'name'};
            # Need to save profofile with the service for later use with grpcurl
            ${$services_ref}{$package}{$serviceName}{$rpcName} = {'request' => $request, 'reply' => $reply, 'protofile' => $protofile};
         }

         # "message HelloRequest {", Get the message name.
         if ($line =~ /^message\s+(\w+)\s*{$/) {
            push(@level, {'name' => $1, 'type' => 'message'});
            ${$messages_ref}{$package}{$1} = [];
         }

         # "string name = 1;"
         if (($line =~ /^(.+)\s+(\w+)\s+=\s+(\d+);/) && @level && $level[-1]{'type'} eq 'message') {
            my ($type, $name, $pos) = ($1, $2, $3);
            my $messageName = $level[-1]{'name'};
            # my ($repeated, $optional);
            my $repeated = $type =~ s/\s*repeated\s*//g;
            my $optional = $type =~ s/\s*optional\s*//g;
            ${${$messages_ref}{$package}{$messageName}}[$pos - 1] = {'type' => $type, 'name' => $name, 'repeated' => $repeated, 'optional' => $optional}
         }

         # "enum Blah {". Deal with enums so we can at least ignore them
         if ($line =~ /^enum\s+(\w+)\s*{$/) {
            push(@level, {'name' => $1, 'type' => 'enum'});
         }

         # "}", close multiline thing based on whats the last thing open
         if ($line =~ /^}$/) {
            pop(@level);
         }
      }
      close($protofile_h);

   } else {
      warn(sprintf("Warning, the following file does not exist or is not readable: %s\n", $protofile));
   }
   return(0);
}

main();
exit(0);
