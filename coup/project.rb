require 'digest/md5'
require 'erb'
require 'fileutils'

# these are equivalent, but the first only works on ruby-1.9
# require_relative './coup/utils.rb'
dir = File.dirname(if File.symlink?(__FILE__) then File.readlink(__FILE__) else __FILE__ end)
require File.join(dir, "utils.rb")

################################################################################
class CoupProject

  ########################################
  def all_packages
    @all_packages
  end

  def installed_packages_file
    File.join(@project_dir, "installed_packages")
  end

  def project_db_path
    File.join(@project_dir, "packages.conf.d")
  end

  def cabal_config_path
    File.join(@project_dir, "cabal.config")
  end

  def get_package_path(package, digest)
    File.join(@coup_user_dir, "packages", package + '-' + digest)
  end

  def get_package_db_path(package_path)
    File.join(package_path, "package.conf.d")
  end

  def get_installed_packages
    if File.exist? installed_packages_file
      package_db_list = File.read(installed_packages_file).split("\n")
    else
      package_db_list = []
    end
    return package_db_list
  end

  def cabal_db_flags
    get_installed_packages.map {|x| "--package-db=#{x}"}
  end


  ########################################
  def initialize(coup_user_dir, project_file)
    @coup_user_dir = coup_user_dir

    if project_file.nil?
      raise "No project file found, please specify one with -p"
    elsif not File.exist?(project_file)
      raise "Project file does not exist: #{project_file}"
    end

    packages = read_package_list(project_file)

    # packages is a dictionary of package lists, indexed by repo name.
    # package_list is a flattened list of all packages.
    @all_packages = []
    packages.each do |hackage_url, list|
      package_list = @all_packages + list
    end
    @all_packages.sort!

    # TODO warn if more than one version of same package

    project_name    = File.basename(project_file.chomp(File.extname(project_file)))
    digest          = Digest::MD5.hexdigest(@all_packages.join) # use package_list.hash here?
    @ghc_version    = get_ghc_version()
    @project_dir     = File.join( @coup_user_dir,
                                  "projects",
                                  "#{project_name}-#{digest}",
                                  "ghc-#{@ghc_version}" )

    @repo_dir       = File.join(@project_dir, 'packages')
    @cache_dir      = File.join(@coup_user_dir, 'cache')

    FileUtils.mkdir_p(@project_dir)
    FileUtils.cp(project_file, File.dirname(@project_dir))
    sync_local_repo(@repo_dir, @cache_dir, packages)

    setup_cabal

    project_db_list = get_installed_packages
    project_db_list << get_ghc_global_package_path
    ENV['GHC_PACKAGE_PATH'] = project_db_list.join(':')
  end

  ########################################
  def setup_cabal

    if not File.exists?(project_db_path)
      system "ghc-pkg", "init", project_db_path
      unless $?.success? then exit 1 end
    end

    if not File.exist?(cabal_config_path)

      cabal_env = {}
      cabal_env['local-repo']           = @repo_dir
      cabal_env['with-compiler']        = 'ghc-' + @ghc_version
      cabal_env['package-db']           = project_db_path
      # cabal_env['build-summary']        = File.join(dir, "logs", "build.log")
      # cabal_env['executable-stripping'] = "True"

      f = File.new(cabal_config_path, "w")
      cabal_env.each do |key, val|
        f.write(key + ': ' + val + "\n")
      end
      # note: the prefix for this project should never be used, because every call
      # to 'cabal' should its own --prefix switch.

      # binaries are always installed to the project dir, not the prefix for a
      # particular package.

      template = ERB.new <<-EOF
install-dirs user
  prefix: <%= @project_dir %>
  bindir: <%= @project_dir %>/bin
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
    ENV['CABAL_CONFIG'] = cabal_config_path
  end

  ########################################
  # this function name is vague.  it uses cabal to get the package dependencies
  # for a list of packages, and creates a package configuration dictionary.
  # note: you can pass the empty list to get the dependencies for a .cabal file in
  # the current directory.
  def get_install_plan(pkgs, flags)
    # note: we always perform the dry run with no local databases.
    # use "--global" so that local user packages (in ~/.cabal, ~/.ghc) are not used.

    args = flags + ["--global", "--dry-run-show-deps", "-v0" ] + cabal_db_flags + pkgs
    out = `cabal install #{args.join(' ')}`
    unless $?.success? then exit 1 end

    packages = []

    # the line is a list of whitespace-separated packages.  the first is the
    # package, and the rest are its dependencies.
    out.each_line do |line|

      pkgs = line.chomp.split(/\s+/)
      pkg = pkgs.slice!(0) # pkg is the first, and pkgs is the rest (the deps)

      digest          = Digest::MD5.hexdigest(pkgs.sort.join(' '))
      package_path    = get_package_path(pkg, digest)
      package_db_path = get_package_db_path(package_path)

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

  ########################################
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

  ########################################
  # given a list of packages, install those packages and their dependencies, each
  # in its own package database.  if package_list is empty, then install the cabal
  # package from the current directory.
  def install_packages(package_list, deps_only, flags)

    packages = get_install_plan(package_list, flags)

    dry_run = flags.include?("--dry-run")

    installed_packages = get_installed_packages

    # the file installed_packages contains the path to each installed package database.
    f = File.open(installed_packages_file, "a")

    packages.each_index do |i|

      package_name    = packages[i]['package_name']
      package_db_path = packages[i]['package_db_path']
      package_deps    = packages[i]['package_deps']
      package_path    = packages[i]['package_path']

      # check if we are installing a package from the current directory.
      final_curdir_package = package_list.empty? && i == packages.length - 1

      # check if the package is already installed
      out = `ghc-pkg-#{@ghc_version} --package-conf=#{package_db_path} describe #{package_name} 2>/dev/null`

      # if the ghc-pkg command was successful, then this package is installed, so skip it.
      # however, do not skip if we're installing from a .cabal in the current directory.
      if $?.success? and not final_curdir_package
        # now, check if the installed package is registered with this project.
        if installed_packages.include?(package_db_path)
          # hmmm... this means that cabal thinks we should install the package,
          # even though it already exists in the database.  maybe this is an error?
          print "Skipping #{package_name}, because it is already installed for this project\n"
        else
          print "Registering existing package #{package_name} with this project\n"
          f.write(package_db_path + "\n")
          f.fsync
        end
      elsif deps_only && (package_list.include?(package_name) || final_curdir_package)
        print "Skipping #{package_name}, because we are only installing dependencies\n"
      else
        # if not dry_run
        #   if File.exist?(package_db_path)
        #     FileUtils.rm_rf(package_db_path)
        #   end
        # end

        # even if we're doing a dry-run, we have to make sure the db exists
        if not File.exist?(package_db_path)
          system "ghc-pkg", "init", package_db_path
          unless $?.success? then exit 1 end
        end

        ########################################
        # setup the list of package databases

        # get database path to each of this package's dependencies.
        package_db_list = lookup_package_deps(packages, package_deps).compact

        # remove the nil entries (dependencies that are in global db)
        package_db_list.compact!

        # add the packages that are already installed, and remove duplicates.
        # this is necessary to discover packages that are not in the project repo,
        # but were installed from a local .cabal file.
        package_db_list = (installed_packages + package_db_list).uniq

        # add the path for this package's db on the end, causing it to get registered there.
        package_db_list << package_db_path

        ########################################
        # run the cabal command
        package_db_args = package_db_list.map {|x| "--package-db=#{x}" }

        # TODO sanity check that cabal only installs the one package, and no deps.

        if dry_run
          puts "Would install #{package_name}"
        elsif final_curdir_package
          system "cabal", "install", "--prefix=#{package_path}", *(package_db_args + flags)
          unless $?.success? then exit 1 end
        else
          system "cabal", "install", "--prefix=#{package_path}", *(package_db_args + flags + [package_name])
          unless $?.success? then exit 1 end
        end
        if not dry_run
          f.write(package_db_path + "\n")
          f.fsync
        end
      end
    end
    f.close
  end

end
