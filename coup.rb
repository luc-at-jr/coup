#!/usr/bin/env ruby

require 'digest/md5'
require 'erb'
# require 'curb'
require 'fileutils'

# config file
#  - support global config file and project config file
#  - hackage repositories
#  - list of project dirs (so we can run them without cd-ing into them)
#  - use yaml?

# generate .hackage file
#  - cabal install --dry-run
#  - need to handle the janrain-* packages that aren't on hackage

# ways of specifying a project:
#  - default to .cabal file in current directory
#  - path to .cabal file (.cabal extension is optional)
#  - name of a project from config file, which tells the dir where located

################################################################################
# utilities

def parse_package_name_version(str)
  x = str.split('-')
  if (x.length < 2)
    throw "malformed package name"
  end

  name = x[0..-2].join('-')
  version = x[-1]

  return name, version
end

def read_package_list(path)
  # TODO check if file exists, return null?
  packages = []

  x = File.read(path)
  x.lines do |line|
    # TODO validate the package name?
    packages << line.chomp("\n")
  end

  return packages, Digest::MD5.hexdigest(x)
end

def find_cabal_file(dir)
  files = Dir.entries(dir)
  cabal_files = files.find_all {|x| File.extname(x) == ".cabal" }

  return case cabal_files.length
         when 0 then throw "No cabal file found"
         when 1 then ['.', cabal_files[0].chomp(".cabal")]
         else throw "Multiple cabal files found"
         end
end

def get_ghc_version()
  ghc_version = ENV['GHC_VERSION']
  if not ghc_version
    ghc_version = '6.12.3' # TODO
  end
  return ghc_version
end

################################################################################

packages, digest = read_package_list(ARGV[0])

coup_user_dir = File.join(Dir.home, ".coup")
cache_dir     = File.join(coup_user_dir, 'cache')
ghc_version   = get_ghc_version()
project_dir   = File.join(coup_user_dir, digest + '-' + ghc_version)

FileUtils.mkdir_p(project_dir)
FileUtils.mkdir_p(cache_dir)

########################################
# generate cabal.config if it doesn't exist
# TODO let user specify values for the many cabal config options.
cabal_env = {}
# cabal_env['remote-repo']          = "dummy:http://DUMMY_REMOTE_REPO_TO_SHUT_UP_CABAL_WARNINGS"
# cabal_env['remote-repo-cache']    = File.join(coup_user_dir, 'cache')
cabal_env['local-repo']           = File.join(project_dir, 'packages')
cabal_env['with-compiler']        = 'ghc-' + ghc_version
cabal_env['package-db']           = File.join(project_dir, 'packages-' + ghc_version + '.conf')
cabal_env['build-summary']        = File.join(project_dir, "logs", "build.log")
cabal_env['executable-stripping'] = "True"

# FileUtils.mkdir_p(cabal_env['remote-repo-cache'])

cabal_config = File.join(project_dir, "cabal.config")
if not File.exist?(cabal_config)
  f = File.new(cabal_config, "w")
  cabal_env.each do |key, val|
    f.write(key + ': ' + val + "\n")
  end
  prefix = File.join(project_dir, 'ghc-' + ghc_version)
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

if not Dir.exists?(cabal_env['package-db'])
  system "ghc-pkg-" + ghc_version, "init", cabal_env['package-db']
end

########################################

# TODO figure out the global package database;
# for now, get it from GHC_GLOBAL_PACKAGE_PATH

FileUtils.mkdir_p(cabal_env['local-repo'])

index_file = "00-index.tar"
index_path = File.join(cabal_env['local-repo'], index_file)

if not File.exists?(index_path)
  Dir.chdir(cabal_env['local-repo'])
  FileUtils.touch("dummy")
  system "tar", "cf", "00-index.tar", "dummy"
end

hackage_url = "http://hackage.haskell.org/packages/archive"
packages.each do |name_version|
  name, version = parse_package_name_version name_version

  tar_file    = name_version + '.tar.gz'
  tar_path    = File.join(cache_dir, name, version, tar_file)
  cabal_file  = name + ".cabal"
  cabal_path  = File.join(cabal_env['local-repo'], name, version, cabal_file)

  if not File.exists?(tar_path)
    dir = File.dirname(tar_path)
    FileUtils.mkdir_p(dir)
    Dir.chdir(dir)
    system "wget", hackage_url + '/' + name + '/' + version + '/' + tar_file
  end

  if not File.exists?(cabal_path)
    FileUtils.mkdir_p(File.dirname(cabal_path))

    # get the .cabal file from the tarball
    fin = IO.popen(["tar xOf ", tar_path, ' ', name_version, '/', cabal_file].join)
    x = fin.read

    f = File.new(cabal_path, "w")
    f.write(x)
    f.close

    system "tar", "uf", index_file, File.join(".", name, version, cabal_file)
    File.symlink(tar_path, File.join(name, version, tar_file))
  end
end

########################################
ENV['GHC_PACKAGE_PATH'] = cabal_env['package-db'] + ':' + ENV['GHC_GLOBAL_PACKAGE_PATH']
ENV['CABAL_CONFIG'] = cabal_config

system "cabal", "list"
system "ghc-pkg", "list"

########################################
