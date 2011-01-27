#!/usr/bin/env ruby

require 'digest/md5'
require 'erb'
# require 'curb'
require 'fileutils'
require 'optparse'

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

# config file
#  - support global config file and project config file
#  - list of project dirs (so we can run them without cd-ing into them)
#  - use yaml for config files?

# generate .hackage file with cabal install --dry-run

# ways of specifying a project:
#  - default to .cabal file in current directory
#  - path to .cabal file (.cabal extension is optional)
#  - name of a project from config file, which tells the dir where located

################################################################################
# utilities

def parse_package_name_version(str)
  x = str.split('-')
  if (x.length < 2)
    throw "malformed package name: " + str
  end

  name = x[0..-2].join('-')
  version = x[-1]

  return name, version
end

def old_hackage?(url)
  return (url.index("hackage.haskell.org") and true)
end

def read_package_list(path)
  # TODO check if file exists, return nil?
  current_repo = "http://hackage.haskell.org/packages/archive"
  packages = {}

  File.new(path).each_line do |line|
    line = line.chomp
    if not line.empty? and line[0].chr != '#'
      if line[0].chr == '[' and line[-1].chr == ']'
        current_repo = line[1..-2]
      else
        # TODO validate the package name?
        if not packages[current_repo]
          packages[current_repo] = []
        end
        packages[current_repo] << line
      end
    end
  end

  return packages
end

def get_ghc_version()
  ghc_version = ENV['GHC_VERSION']
  if not ghc_version
    ghc = ENV['GHC'] || 'ghc'
    fin = IO.popen([ghc, "--version"].join(' '))
    ghc_version = fin.read.chomp.split(' ')[-1]
    fin.close
  end
  return ghc_version
end

def get_ghc_global_package_path()
  ghc_pkg = ENV['GHC_PKG'] || 'ghc-pkg'
  fin = IO.popen("strings `which #{ghc_pkg}` | grep 'topdir=' | cut -d\"\\\"\" -f2")
  p = File.join(fin.read.chomp, "package.conf.d")
  fin.close
  # TODO check that p exists
  return p
end

def find_project_file(dir)
  files = Dir.entries(dir)
  project_files = files.find_all {|x| File.extname(x) == ".hackage" }

  return case project_files.length
         when 0 then
           if dir == '/'
             return nil
           else
             find_project_file(File.dirname(dir))
           end
         when 1 then File.join(dir, project_files[0])
         else throw "Multiple project files found in #{dir.path}"
         end
end

################################################################################

if options[:project].nil?
  options[:project] = find_project_file(workdir)
end

if options[:project].nil?
  throw "No project file found, please specify one with -p"
end

# TODO warn if more than one version of same package
packages = read_package_list(options[:project])

package_list = []
packages.each do |hackage_url, list|
  package_list = package_list + list
end
package_list.sort!

digest = Digest::MD5.hexdigest(package_list.join)

ghc_version   = get_ghc_version()
project_dir   = File.join(coup_user_dir, "#{digest}-#{ghc_version}")

FileUtils.mkdir_p(project_dir)
FileUtils.mkdir_p(cache_dir)

########################################
# generate cabal.config if it doesn't exist
# TODO let user specify values for the many cabal config options.
cabal_env = {}
cabal_env['local-repo']           = File.join(project_dir, 'packages')
cabal_env['with-compiler']        = 'ghc-' + ghc_version
cabal_env['package-db']           = File.join(project_dir, "packages-#{ghc_version}.conf")
cabal_env['build-summary']        = File.join(project_dir, "logs", "build.log")
cabal_env['executable-stripping'] = "True"

cabal_config = File.join(project_dir, "cabal.config")
if not File.exist?(cabal_config)
  f = File.new(cabal_config, "w")
  cabal_env.each do |key, val|
    f.write(key + ': ' + val + "\n")
  end
  prefix = File.join(project_dir, "ghc-#{ghc_version}")
  template = ERB.new <<-EOF
install-dirs user
  prefix: <%= prefix %>
  -- bindir: $prefix/bin
  libdir: $prefix
  libsubdir: $pkgid/lib
  libexecdir: $prefix/$pkgid/libexec
  datadir: $prefix
  datasubdir: $pkgid/share
  docdir: $datadir/$pkgid/doc
  -- htmldir: $docdir/html
  -- haddockdir: $htmldir
EOF

  f.write(template.result(binding))
  f.close
end

########################################
# generate ghc-pkg db if it doesn't exist

if not File.exists?(cabal_env['package-db'])
  system "ghc-pkg-#{ghc_version}", "init", cabal_env['package-db']
end

########################################

FileUtils.mkdir_p(cabal_env['local-repo'])

index_file = "00-index.tar"
index_path = File.join(cabal_env['local-repo'], index_file)

if not File.exists?(index_path)
  Dir.chdir(cabal_env['local-repo'])
  FileUtils.touch("dummy")
  system "tar", "cf", "00-index.tar", "dummy"
end

packages.each do |hackage_url, list|
  list.each do |name_version|
    name, version = parse_package_name_version name_version

    tar_file    = name_version + '.tar.gz'
    tar_path    = File.join(cache_dir, name, version, tar_file)
    cabal_file  = name + ".cabal"
    cabal_path  = File.join(cabal_env['local-repo'], name, version, cabal_file)

    if not File.exists?(tar_path)
      dir = File.dirname(tar_path)
      FileUtils.mkdir_p(dir)
      Dir.chdir(dir)
      if old_hackage? hackage_url
        url = "#{hackage_url}/#{name}/#{version}/#{tar_file}"
      else
        url = "#{hackage_url}/#{tar_file}"
      end
      system "wget", url
    end

    if not File.exists?(cabal_path)
      FileUtils.mkdir_p(File.dirname(cabal_path))

      # get the .cabal file from the tarball
      fin = IO.popen("tar xOf #{tar_path} #{name_version}/#{cabal_file}")
      x = fin.read
      fin.close

      f = File.new(cabal_path, "w")
      f.write(x)
      f.close

      Dir.chdir(cabal_env['local-repo'])
      system "tar", "uf", index_file, File.join(".", name, version, cabal_file)
      File.symlink(tar_path, File.join(name, version, tar_file))
    end
  end
end

########################################
ENV['GHC_PACKAGE_PATH'] = cabal_env['package-db'] + ':' + get_ghc_global_package_path()
ENV['CABAL_CONFIG'] = cabal_config

Dir.chdir(workdir)
if not args.empty?
  case args[0]
  when 'install-all' then
    system 'cabal', 'install', *package_list
  else
    cmd = options[:command] || 'cabal'
    system cmd, *args
  end
end

########################################
