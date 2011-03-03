#!/usr/bin/env ruby

require 'digest/md5'
# require 'curb'
require 'fileutils'
require 'optparse'

# these are equivalent, but the first only works on ruby-1.9
# require_relative './coup/utils.rb'

dir = File.dirname(if File.symlink?(__FILE__) then File.readlink(__FILE__) else __FILE__ end)
require File.join(dir, "coup", "utils.rb")
require File.join(dir, "coup", "project.rb")

################################################################################
coup_user_dir = File.join(ENV['HOME'], ".coup")

options = {}

optparse = OptionParser.new do |opts|
  opts.banner = "Usage: coup.rb [options] [command]"

  options[:project] = nil
  options[:verbose] = false

  opts.on( '-v', '--verbose', 'Output more information' ) do
    options[:verbose] = true
  end

  # opts.on( '-c', '--command CMD', "Run command on remaining arguments" ) do |x|
  #   options[:command] = x
  # end

  opts.on( '-p', '--project NAME', 'Select the coup cabal project (name or path)' ) do |p|
    options[:project] = p
  end

  opts.on( '-h', '--help', 'Display this screen' ) do
    puts opts
    exit
  end
end

args = optparse.order(ARGV)

########################################

project = CoupProject.new(coup_user_dir, options)

case args[0]
when 'install-all' then
  project.install_packages(project.all_packages, false, args[1..-1])
when 'install', 'install-deps' then
  deps_only = args[0] == 'install-deps'
  args.shift
  flags, pkgs = args.partition {|x| x[0].chr == '-'}
  project.install_packages(pkgs, deps_only, flags)
when 'cabal', 'configure', 'build', 'clean'
  if args[0] == 'cabal' then args.shift end

  cmd = args[0]
  args.shift

  flags, pkgs = args.partition {|x| x[0].chr == '-'}
  project.run_cabal_command(cmd, pkgs, flags)
when 'describe', 'unregister', 'list', 'check'
  # TODO for unregister, remove the file from the project list.
  cmd = args[0]
  args.shift
  system "ghc-pkg", cmd, *args
else
  if not args.empty?
    # run any command from inside the project environment
    exec *args
  end
end

########################################
