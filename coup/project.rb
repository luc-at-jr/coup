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
    str = package + if @profiling then '-prof-' else '-' end + digest
    File.join(@coup_user_dir, "packages", "ghc-#{@ghc_version}", str)
  end

  def get_package_db_path(package_path)
    File.join(package_path, "package.conf.d")
  end

  # the 'dist' directory for local builds.
  # note: this could be a problem when there are multiple different cabal
  # packages of the same name within a project, such as dummy "test.cabal"
  # projects.
  def get_build_path(name)
    File.join(@project_dir, "dist", name)
  end

  def make_env(package_list)
    ENV['GHC_PACKAGE_PATH'] = (package_list.reverse + [get_ghc_global_package_path]).join(':')
  end

  def add_installed_package(package_db)
    if not @package_db_list.include?(package_db)
      @package_db_list << package_db
      File.open(installed_packages_file, "a") do |f|
        f.write(package_db + "\n")
      end
    end
  end

  def get_installed_packages
    if @package_db_list then return @package_db_list.dup end

    if File.exist? installed_packages_file
      @package_db_list = File.read(installed_packages_file).split("\n")
    else
      @package_db_list = []
    end

    @package_db_list.uniq!
    @package_db_list.delete_if do |x|
      if x.empty?
        true
      elsif File.exist?(x)
        false
      else
        warn "WARNING: package database does not exist, ignoring:"
        warn "         #{x}"
        true
      end
    end
    File.open(installed_packages_file, "w") do |f|
      f.write(@package_db_list.join("\n") + "\n")
    end
    return @package_db_list.dup
  end

  def run_cabal_command(cmd, pkgs, flags, extra_db_path = nil, capture_output = false)
    args = pkgs + flags

    # these commands take the --package-db flag.
    if ["configure", "install"].include? cmd
      args = args + cabal_flags(extra_db_path)
    end

    # when any of these commands is run without any packages,
    # then we are running cabal on a .cabal in the current directory.
    # find the name of the .cabal file and use it to create a builddir flag.
    if pkgs.empty? && ["configure", "install", "build", "clean"].include?(cmd)
      build_path = get_build_path(find_cabal_file)
      args << "--builddir=#{build_path}"
      FileUtils.rm_rf("./dist")
      system "ln", "-sf", build_path, "./dist"
    end

    if capture_output
      out = `cabal #{cmd} #{args.join(' ')}`
      unless $?.success? then
        puts out
        exit 1
      end
      return out.split("\n")
    else
      system "cabal", cmd, *args
      unless $?.success? then exit 1 end
    end
  end

  def old_cabal_command(cmd, pkgs=[], flags=[], extra_db_path=nil, capture_output=false)
    ENV['CABAL_CONFIG'] = File.join(ENV['HOME'],'/.cabal/config')
    run_cabal_command(cmd, pkgs, flags, extra_db_path, capture_output)
    ENV['CABAL_CONFIG'] = cabal_config_path
  end

  def find_cabal_file
    cabal_files = Dir.entries(".").find_all {|x| File.extname(x) == ".cabal" }
    case cabal_files.length
    when 0 then raise 'No cabal file found'
    when 1 then cabal_files[0].chomp(".cabal")
    else raise 'Multiple cabal files found'
    end
  end

  def cabal_flags(extra_db_path = nil)

    if @profiling then
      flags = [ "--enable-library-profiling",
                "--enable-executable-profiling" ]
    else
      flags = []
    end

    package_list = get_installed_packages
    if extra_db_path
      package_list.delete(extra_db_path)
      package_list << extra_db_path
    end
    make_env(package_list)
    return flags + package_list.map {|x| "--package-db=#{x}"}
  end

  ########################################
  def initialize(coup_user_dir, options)
    @profiling = options[:profiling]
    @verbose   = options[:verbose]

    project_file = options[:project] || find_project_file(Dir.getwd)
    puts "Loading project #{project_file} ..." if @verbose

    require_command("cabal")
    out = `cabal install --help`
    unless out =~ /dry-run-show-deps/
      raise "cabal-install does not support --dry-run-show-deps option"
    end

    @coup_user_dir = coup_user_dir

    if project_file.nil?
      raise "No project file found, please specify one with -p"
    elsif not File.exist?(project_file)
      raise "Project file does not exist: #{project_file}"
    end

    packages = read_package_list(project_file)

    # packages is a dictionary of package lists, indexed by repo name.
    # all_packages is a flattened list of all packages.
    @all_packages = []
    packages.each do |hackage_url, list|
      @all_packages = @all_packages + list
    end
    @all_packages.sort!

    all_packages.each_index do |i|
      if (i < all_packages.length-1)
        pkg1 = all_packages[i]
        pkg2 = all_packages[i+1]

        name1, version1 = parse_package_name_version(pkg1)
        name2, version2 = parse_package_name_version(pkg2)
        basename = File.basename(project_file)
        if name1 == name2
          if version1 == version2
            warn "WARNING: In #{basename}, package #{pkg1} is listed twice."
          else
            warn "WARNING: In #{basename}, multiple versions of package: #{pkg1}, #{pkg2}."
          end
        end
      end
    end

    project_name    = File.basename(project_file.chomp(File.extname(project_file)))
    digest          = Digest::MD5.hexdigest(@all_packages.join) # use all_packages.hash here?
    @ghc_version    = get_ghc_version()

    project_basedir  = File.join(@coup_user_dir, "projects", "#{project_name}-#{digest}")

    @project_dir     = File.join(project_basedir,
                                 "ghc-#{@ghc_version}" + if @profiling then "-prof" else "" end)
    puts "Project directory is: #{@project_dir}" if @verbose

    @repo_dir       = File.join(project_basedir, 'packages')
    @cache_dir      = File.join(@coup_user_dir, 'cache')

    FileUtils.mkdir_p(@project_dir)
    FileUtils.cp(project_file, File.dirname(@project_dir))
    sync_local_repo(@repo_dir, @cache_dir, packages)

    setup_cabal

    make_env(get_installed_packages)
  end

  ########################################
  def setup_cabal

    if not File.exists?(project_db_path)
      system "ghc-pkg", "init", project_db_path
      unless $?.success? then exit 1 end
    end

    if not File.exist?(cabal_config_path)
      puts "Creating cabal configuration in #{cabal_config_path}"

      cabal_env = {}
      cabal_env['local-repo']           = @repo_dir
      cabal_env['with-compiler']        = 'ghc-' + @ghc_version
      cabal_env['package-db']           = project_db_path
      cabal_env['world-file']           = File.join(@project_dir, "world")
      # cabal_env['build-summary']        = File.join(dir, "logs", "build.log")
      # cabal_env['executable-stripping'] = "True"

      f = File.new(cabal_config_path, "w")
      cabal_env.each do |key, val|
        f.write(key + ': ' + val + "\n")
      end

      template = ERB.new <<-EOF
install-dirs user
  prefix: <%= @project_dir %>
  bindir: $prefix/bin
  libdir: $prefix
  libsubdir: lib
  libexecdir: $prefix/libexec
  datadir: $prefix
  datasubdir: share
  docdir: $datadir/doc
  htmldir: $docdir/html
  haddockdir: $htmldir
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
    get_installed_packages  # initializes @package_db_list

    puts "Getting install plan ..."
    # note: we always perform the dry run with no local databases.
    # use "--global" so that local user packages (in ~/.cabal, ~/.ghc) are not used.

    args = flags + ["--global", "--dry-run-show-deps", "-v0" ] + cabal_flags + pkgs
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

    packages.each_index do |i|

      package_name    = packages[i]['package_name']
      package_db_path = packages[i]['package_db_path']
      package_deps    = packages[i]['package_deps']
      package_path    = packages[i]['package_path']

      # check if we are installing a package from the current directory.
      final_curdir_package = package_list.empty? && i == packages.length - 1

      skip = false

      # check if the package is already installed
      out = `ghc-pkg-#{@ghc_version} --package-conf=#{package_db_path} describe #{package_name} 2>/dev/null`

      if $?.success? and not final_curdir_package and not flags.include?("--reinstall")
        # now, check if the installed package is registered with this project.
        if @package_db_list.include?(package_db_path)
          warn "WARNING: package #{package_name} is already installed for this project, "
          warn "         but cabal wants to reinstall it, so we're going to!"
        else
          print "Registering existing package #{package_name} with this project\n" if @verbose
          add_installed_package(package_db_path)
          skip = true
        end
      elsif deps_only && (package_list.include?(package_name) || final_curdir_package)
        print "Skipping #{package_name}, because we are only installing dependencies\n" if @verbose
        skip = true
      end

      if not skip
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
        # run the cabal command

        if dry_run
          puts "Would install #{package_name}" + if @profiling then " (profiling)" else "" end
        else
          if final_curdir_package then
            pkgs = []
          else
            pkgs = [package_name]
          end
          lines = run_cabal_command("install", pkgs, flags + ["-v1", "--dry-run"], package_db_path, true)
          xs = lines.drop(2)
          if xs.length != 1
            warn "ERROR: cabal should only install one package, #{package_name}."
            warn "       However, cabal says it's going to install these packages:"
            warn "       #{xs.join(', ')}"
            warn "       You may have to remove these packages manually..."
            exit 1
          end
          run_cabal_command("install", pkgs, flags + ["--prefix=#{package_path}"], package_db_path)
          unless $?.success? then exit 1 end
          add_installed_package(package_db_path)
        end
      end
    end
  end

  def list_updated(packages_path)
    puts 'Downloading most recent package list. This might take a while.'
    old_cabal_command('update',[],[],nil,true)
    puts 'Searching for updated package versions'
    package_hash = {}
    updated = {}

    @all_packages.each do |package|
      name, version = parse_package_name_version package
      package_hash.store(name, version)
    end

    package_list = Dir.entries(packages_path).inject([]) do |lst, repo|
      dir = File.join(packages_path, repo)
      if repo[0] != '.' && File.directory?(dir)

        lst = Dir.entries(dir).inject(lst) do |lst_, index|
          if index =~ /\w+.tar\Z/
            lst_ = lst_ + `tar -tf #{dir}/#{index}`.split
          end
          lst_
        end
      end
      lst
    end

    package_list.each do |pkg_str|
      name, version = pkg_str.split('/')
      if package_hash[name]
        if updated[name]
          updated[name] = version if updated[name].to_f < version.to_f
        else
          updated[name] = version if package_hash[name].to_f < version.to_f
        end
      end
    end

    unless updated.empty?
      puts "The following updates are available:"
      updated.each_pair do |key,val|
        puts "\t#{key}-#{package_hash[key]} -> #{key}-#{val}"
      end
    else
      puts "All your packages are up to date!"
    end
  end

end
