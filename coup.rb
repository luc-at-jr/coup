#!/usr/bin/env ruby

require 'digest/md5'
# require 'curb'
require 'fileutils'
require 'optparse'

# these are equivalent, but the first only works on ruby-1.9
# require_relative './coup/utils.rb'
dir = File.dirname(File.realpath(__FILE__))
require File.join(dir, "coup", "utils.rb")

################################################################################
coup_user_dir = File.join(ENV['HOME'], ".coup")
cache_dir     = File.join(coup_user_dir, 'cache')
workdir       = Dir.getwd

options = {}

optparse = OptionParser.new do |opts|
  opts.banner = "Usage: coup.rb [options] [command]"

  options[:project] = nil
  options[:verbose] = false

  opts.on( '-v', '--verbose', 'Output more information' ) do
    options[:verbose] = true
  end

  opts.on( '-c', '--command CMD', "Run command on remaining arguments" ) do |x|
    options[:command] = x
  end

  opts.on( '-p', '--project NAME', 'Select the coup cabal project (name or path)' ) do |p|
    options[:project] = p
  end

  opts.on( '-h', '--help', 'Display this screen' ) do
    puts opts
    exit
  end
end

args = optparse.order(ARGV)

################################################################################

project_file = options[:project] || find_project_file(workdir)

if project_file.nil?
  raise "No project file found, please specify one with -p"
elsif not File.exist?(project_file)
  raise "Project file does not exist: #{project_file}"
end

packages = read_package_list(project_file)

project_name = project_file.chomp(File.extname(project_file))

# packages is a dictionary of package lists, indexed by repo name.
# package_list is a flattened list of all packages.
package_list = []
packages.each do |hackage_url, list|
  package_list = package_list + list
end
package_list.sort!

# TODO warn if more than one version of same package

# use package_list.hash here?
digest = Digest::MD5.hexdigest(package_list.join)

ghc_version   = get_ghc_version()
project_dir   = File.join(coup_user_dir, "projects", "#{project_name}-#{digest}-#{ghc_version}")
repo_dir      = File.join(project_dir, 'packages')

FileUtils.mkdir_p(project_dir)

########################################

sync_local_repo(repo_dir, cache_dir, packages)

cabal_config, package_db_path = gen_cabal_config(project_dir, repo_dir, ghc_version)

# generate ghc-pkg db if it doesn't exist
if not File.exists?(package_db_path)
  unless system "ghc-pkg-#{ghc_version}", "init", package_db_path then exit 1 end
end

########################################
ENV['GHC_PACKAGE_PATH'] = package_db_path + ':' + get_ghc_global_package_path()
ENV['CABAL_CONFIG'] = cabal_config

Dir.chdir(workdir)
case args[0]
when 'install-all' then
  unless system 'cabal', 'install', *package_list then exit 1 end
else
  cmd = options[:command] || 'cabal'
  unless system cmd, *args then exit 1 end
end

########################################
