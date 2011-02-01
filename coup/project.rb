require 'digest/md5'
require 'erb'
require 'fileutils'

# these are equivalent, but the first only works on ruby-1.9
# require_relative './coup/utils.rb'
dir = File.dirname(File.realpath(__FILE__))
require File.join(dir, "utils.rb")

################################################################################
def setup_cabal(project_dir, repo_dir, ghc_version)

  dummy_db_path = File.join(project_dir, "packages-#{ghc_version}.conf.d")

  if File.exists?(dummy_db_path)
    FileUtils.rm_rf(dummy_db_path)
  end

  system "ghc-pkg", "init", dummy_db_path
  unless $?.success? then exit 1 end

  # TODO let user specify values for the many cabal config options.
  cabal_env = {}
  cabal_env['local-repo']           = repo_dir
  cabal_env['with-compiler']        = 'ghc-' + ghc_version
  cabal_env['package-db']           = dummy_db_path
  # cabal_env['build-summary']        = File.join(dir, "logs", "build.log")
  # cabal_env['executable-stripping'] = "True"

  cabal_config = File.join(project_dir, "cabal.config")
  if File.exist?(cabal_config)
    File.delete(cabal_config)
  end

  f = File.new(cabal_config, "w")
  cabal_env.each do |key, val|
    f.write(key + ': ' + val + "\n")
  end
  # note: the prefix for this project should never be used, because every call
  # to 'cabal' should its own --prefix switch.

  # binaries are always installed to the project dir, not the prefix for a
  # particular package.

  template = ERB.new <<-EOF
install-dirs user
  prefix: DUMMY
  bindir: <%= project_dir %>/bin
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

  ENV['CABAL_CONFIG'] = cabal_config
end

################################################################################
# this function name is vague.  it uses cabal to get the package dependencies
# for a list of packages, and creates a package configuration dictionary.
# note: you can pass the empty list to get the dependencies for a .cabal file in
# the current directory.
def get_install_plan(coup_user_dir, package_list)
  # TODO cache the package configuration based on hash of package_list,
  #      and only use cabal --dry-run if no cache exists.

  # note: we always perform the dry run with no local databases.
  # use "--global" so that local user packages (in ~/.cabal, ~/.ghc) are not used.
  out = `cabal install --global -v0 --dry-run #{package_list.join(" ")}`
  unless $?.success? then exit 1 end

  packages = []

  # the line is a list of whitespace-separated packages.  the first is the
  # package, and the rest are its dependencies.
  out.each_line do |line|

    pkgs = line.chomp.split(/\s+/)
    pkg = pkgs.slice!(0) # pkg is the first, and pkgs is the rest (the deps)

    digest = Digest::MD5.hexdigest(pkgs.sort.join(' '))
    package_path = File.join(coup_user_dir, "packages", pkg + '-' + digest)

    package_db_path = File.join(package_path, "package.conf.d")

    package = {
      'package_name'    => pkg,
      'package_deps'    => pkgs,
      'package_path'    => package_path,
      'package_db_path' => package_db_path
    }

    packages << package
  end

  return packages

end

################################################################################
def load_project(coup_user_dir, project_file)
  if project_file.nil?
    raise "No project file found, please specify one with -p"
  elsif not File.exist?(project_file)
    raise "Project file does not exist: #{project_file}"
  end

  packages = read_package_list(project_file)

  # packages is a dictionary of package lists, indexed by repo name.
  # package_list is a flattened list of all packages.
  package_list = []
  packages.each do |hackage_url, list|
    package_list = package_list + list
  end
  package_list.sort!

  # TODO warn if more than one version of same package

  ghc_version  = get_ghc_version()
  project_name = File.basename(project_file.chomp(File.extname(project_file)))
  digest       = Digest::MD5.hexdigest(package_list.join) # use package_list.hash here?
  project_dir  = File.join(coup_user_dir, "projects", "#{project_name}-#{digest}-#{ghc_version}")

  repo_dir     = File.join(project_dir, 'packages')
  cache_dir    = File.join(coup_user_dir, 'cache')

  FileUtils.mkdir_p(project_dir)
  sync_local_repo(repo_dir, cache_dir, packages)

  setup_cabal(project_dir, repo_dir, ghc_version)

  return project_dir, repo_dir, ghc_version, package_list
end

# get all package db paths that a package depends on
def lookup_package_deps (packages, pkg_deps)
  # kinda inefficient...
  deps = []
  pkg_deps.each do |x|
    dep_package = packages.find {|pkg| pkg['package_name'] == x}
    if dep_package then
      deps << dep_package['package_db_path']
      deps = deps + lookup_package_deps(packages, dep_package['package_deps'])
    end
  end
  return deps.uniq
end

################################################################################
def install_package(coup_user_dir, project_dir, ghc_version, package_list)

  packages = get_install_plan(coup_user_dir, package_list)

  # the file installed_packages contains the path to each installed package database.
  installed_packages_file = File.join(project_dir, "installed_packages")
  if File.exist? installed_packages_file
    installed_packages = File.read(installed_packages_file).split("\n")
  else
    installed_packages = []
  end

  f = File.open(installed_packages_file, "a")

  packages.each do |package|

    package_name    = package['package_name']
    package_db_path = package['package_db_path']
    package_deps    = package['package_deps']
    package_path    = package['package_path']

    # check if the package is already installed
    out = `ghc-pkg-#{ghc_version} --package-conf=#{package_db_path} describe #{package_name} 2>/dev/null`

    # if the ghc-pkg command was successful, then this package is installed.
    # now, check if it is registered with this project.
    if $?.success?
      if installed_packages.index(package_db_path)
        print "Skipping #{package_name}, because it is already installed for this project\n"
      else
        print "Registering existing package #{package_name} with this project\n"
        f.write(package_db_path + "\n")
        f.fsync
      end
    else
      if File.exist?(package_db_path)
        FileUtils.rm_rf(package_db_path)
      end

      system "ghc-pkg", "init", package_db_path
      unless $?.success? then exit 1 end

      ########################################
      # setup the list of package databases

      # get database path to each of this package's dependencies.
      package_db_list = lookup_package_deps(packages, package_deps)

      # remove the nil entries (dependencies that are in global db)
      package_db_list.compact!

      # add the path for this package's db, causing it to get registered there.
      package_db_list << package_db_path

      ########################################
      # run the cabal command
      package_db_args = package_db_list.map {|x| "--package-db=#{x}" }

      # TODO sanity check that cabal only installs the one package, and no deps.
      system "cabal", "install", "--prefix=#{package_path}", *package_db_args, package_name
      unless $?.success? then exit 1 end
      f.write(package_db_path + "\n")
      f.fsync
    end
  end
  f.close
end
