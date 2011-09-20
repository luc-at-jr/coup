require 'erb'

################################################################################
def require_command(name)
  `which #{name}`
  if not $?.success?
    raise "Cannot find #{name}"
  end
end

################################################################################
def parse_package_name_version(str)
  x = str.split('-')
  if (x.length < 2)
    raise "malformed package name: " + str
  end

  name = x[0..-2].join('-')
  version = x[-1]

  return name, version
end

################################################################################
def old_hackage?(url)
  return (url.index("hackage.haskell.org") and true)
end

################################################################################
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

################################################################################
def get_ghc_version()
  ghc = ENV['GHC'] || 'ghc'
  require_command(ghc)
  fin = IO.popen([ghc, "--numeric-version"].join(' '))
  ghc_version = fin.read.chomp
  fin.close
  if ghc_version and ghc_version.split('.').length == 3
    return ghc_version
  else
    raise "Could not determine ghc version"
  end
end

################################################################################
def compare_versions(str1, str2)
  as = str1.split('.')
  bs = str2.split('.')

  (0..[as.length,bs.length].max - 1).each {|i|
    if as[i].nil?
      return -1
    elsif bs[i].nil? || as[i].to_i > bs[i].to_i
      return 1
    elsif as[i].to_i < bs[i].to_i
      return -1
    end
  }
  return 0
end

################################################################################
def get_ghc_global_package_path()
  ghc_pkg = ENV['GHC_PKG'] || 'ghc-pkg'
  require_command(ghc_pkg)
  fin = IO.popen("strings `which #{ghc_pkg}` | grep 'topdir=' | cut -d\"\\\"\" -f2")
  p = File.join(fin.read.chomp, "package.conf.d")
  fin.close
  if File.exists?(p)
    return p
  else
    raise "GHC package database (#{p}) does not exist"
  end
end

################################################################################
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
         else raise "Multiple project files found in #{dir}"
         end
end

################################################################################
def sync_local_repo(repo_dir, cache_dir, packages)
  prev_dir = Dir.getwd

  FileUtils.mkdir_p(repo_dir)
  FileUtils.mkdir_p(cache_dir)

  index_file = "00-index.tar"
  index_path = File.join(repo_dir, index_file)

  if not File.exists?(index_path)
    Dir.chdir(repo_dir)
    FileUtils.touch("dummy")
    system "tar", "cf", "00-index.tar", "dummy"
    unless $?.success? then exit 1 end
  end

  packages.each do |hackage_url, list|
    list.each do |name_version|
      name, version = parse_package_name_version name_version

      tar_file    = name_version + '.tar.gz'
      tar_path    = File.join(cache_dir, name, version, tar_file)
      cabal_file  = name + ".cabal"
      cabal_path  = File.join(repo_dir, name, version, cabal_file)

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
        unless $?.success? then exit 1 end
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

        Dir.chdir(repo_dir)
        system "tar", "uf", index_file, File.join(".", name, version, cabal_file)
        unless $?.success? then exit 1 end
        File.symlink(tar_path, File.join(name, version, tar_file))
      end
    end
  end
  Dir.chdir(prev_dir)
end

################################################################################
