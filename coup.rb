#!/usr/bin/env ruby

require 'digest/md5'
# require 'curb'
require 'fileutils'
require 'optparse'

# these are equivalent, but the first only works on ruby-1.9
# require_relative './coup/utils.rb'
dir = File.dirname(File.realpath(__FILE__))
require File.join(dir, "coup", "utils.rb")
require File.join(dir, "coup", "project.rb")

################################################################################
coup_user_dir = File.join(ENV['HOME'], ".coup")
workdir       = Dir.getwd

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

project_dir, repo_dir, ghc_version, all_packages =
  load_project(coup_user_dir, options[:project] || find_project_file(workdir))

Dir.chdir(workdir)

case args[0]
when 'install-all' then
  install_packages(coup_user_dir, project_dir, ghc_version, all_packages, false, args[1..-1])
when 'install', 'install-deps' then
  deps_only = args[0] == 'install-deps'
  args.shift
  flags, pkgs = args.partition {|x| x[0] == '-'}
  install_packages(coup_user_dir, project_dir, ghc_version, pkgs, deps_only, flags)
when 'cabal', 'list', 'configure', 'build'
  db_args = get_project_installed_packages(project_dir).map {|x| "--package-db=#{x}"}
  if args[0] == 'cabal' then args.shift end
  system "cabal", *args, *db_args
  unless $?.success? then exit 1 end
else
  # run any command from inside the project environment
  exec *args
end

########################################
