require 'rake/dsl_definition'

module Release
  extend Rake::DSL

  class Release #:nodoc:

    THIS_VERSION_PATTERN  = /(THIS_VERSION|VERSION_NUMBER)\s*=\s*(["'])(.*)\2/

    class << self

      # Use this to specify a different tag name for tagging the release in source control.
      # You can set the tag name or a proc that will be called with the version number,
      # for example:
      #   Release.tag_name = lambda { |ver| "foo-#{ver}" }
      attr_accessor :tag_name

      # Use this to specify a different commit message to commit the buildfile with the next version in source control.
      # You can set the commit message or a proc that will be called with the next version number,
      # for example:
      #   Release.commit_message = lambda { |ver| "Changed version number to #{ver}" }
      attr_accessor :commit_message

      # Use this to specify the next version number to replace VERSION_NUMBER with in the buildfile.
      # You can set the next version or a proc that will be called with the current version number.
      # For example, with the following buildfile:
      #   THIS_VERSION = "1.0.0-rc1"
      #   Release.next_version = lambda { |version|
      #       version[-1] = version[-1].to_i + 1
      #       version
      #   }
      #
      # Release.next_version will return "1.0.0-rc2", so at the end of the release, the buildfile will contain VERSION_NUMBER = "1.0.0-rc1"
      #
      attr_accessor :next_version

      # :call-seq:
      #     add(MyReleaseClass)
      #
      # Add a Release implementation to the list of available Release classes.
      def add(release)
        @list ||= []
        @list |= [release]
      end
      alias :<< :add

      # The list of supported Release implementations
      def list
        @list ||= []
      end

      # Finds and returns the Release instance for this project.
      def find
        unless @release
          klass = list.detect { |impl| impl.applies_to? }
          @release = klass.new if klass
        end
        @release
      end

    end

    # :call-seq:
    #   make()
    #
    # Make a release.
    def make(options)
      @this_version = extract_version
      check
      with_release_candidate_version do |release_candidate_buildfile|
        args = '-S', 'rake', '--rakefile', release_candidate_buildfile
        if options
          args += options.split(' ')
        else
          args << 'clean' << 'build' << 'DEBUG=no'
        end
        ruby *args
      end
      tag_release resolve_tag
      update_version_to_next if this_version != resolve_next_version(this_version)
    end

    def check
      if this_version == resolve_next_version(this_version) && this_version.match(/-SNAPSHOT$/)
        fail "The next version can't be equal to the current version #{this_version}.\nUpdate THIS_VERSION/VERSION_NUMBER, specify Release.next_version or use NEXT_VERSION env var"
      end
    end

    # :call-seq:
    #   extract_version() => this_version
    #
    # Extract the current version number from the buildfile.
    # Raise an error if not found.
    def extract_version
      buildfile = File.read(Rake.application.rakefile.to_s)
      puts "!!!!!!!!!!!!!!!!!!!" + buildfile.scan(THIS_VERSION_PATTERN) 
      buildfile.scan(THIS_VERSION_PATTERN)[0][2]
    rescue
      fail 'Looking for THIS_VERSION = "1.0.0-rc1" in your Buildfile, none found'
    end

    # Use this to specify a different tag name for tagging the release in source control.
    # You can set the tag name or a proc that will be called with the version number,
    # for example:
    #   Release.find.tag_name = lambda { |ver| "foo-#{ver}" }
    # Deprecated: you should use Release.tag_name instead
    def tag_name=(tag_proc)
      Rake.application.deprecated "Release.find.tag_name is deprecated. You should use Release.tag_name instead"
      Release.tag_name=(tag_proc)
    end

    protected

    # the initial value of THIS_VERSION
    attr_accessor :this_version

    # :call-seq:
    #   with_release_candidate_version() { |filename| ... }
    #
    # Yields to block with release candidate buildfile, before committing to use it.
    #
    # We need a Buildfile with upgraded version numbers to run the build, but we don't want the
    # Buildfile modified unless the build succeeds. So this method updates the version number in
    # a separate (Buildfile.next) file, yields to the block with that filename, and if successful
    # copies the new file over the existing one.
    #
    # The release version is the current version without '-SNAPSHOT'.  So:
    #   THIS_VERSION = 1.1.0-SNAPSHOT
    # becomes:
    #   THIS_VERSION = 1.1.0
    # for the release buildfile.
    def with_release_candidate_version
      release_candidate_buildfile = Rake.application.rakefile.to_s + '.next'

      release_candidate_buildfile_contents = change_version { |version|
        version.gsub(/-SNAPSHOT$/, "")
      }
      File.open(release_candidate_buildfile, 'w') { |file| file.write release_candidate_buildfile_contents }
      begin
        yield release_candidate_buildfile
        mv release_candidate_buildfile, Rake.application.rakefile.to_s
      ensure
        rm release_candidate_buildfile rescue nil
      end
    end

    # :call-seq:
    #   change_version() { |this_version| ... } => buildfile
    #
    # Change version number in the current Buildfile, but without writing a new file (yet).
    # Returns the contents of the Buildfile with the modified version number.
    #
    # This method yields to the block with the current (this) version number and expects
    # the block to return the updated version.
    def change_version
      current_version = extract_version
      new_version = yield(current_version)
      buildfile = File.read(Rake.application.rakefile.to_s)
      buildfile.gsub(THIS_VERSION_PATTERN) { |ver| ver.sub(/(["']).*\1/, %Q{"#{new_version}"}) }
    end

    # Return the name of the tag to tag the release with.
    def resolve_tag
      version = extract_version
      tag = Release.tag_name || version
      tag = tag.call(version) if Proc === tag
      tag
    end

    # Return the new value of THIS_VERSION based on the version passed.
    #
    # This method receives the existing value of THIS_VERSION
    def resolve_next_version(current_version)
      next_version = Release.next_version
      next_version ||= lambda { |v|
        snapshot = v.match(/-SNAPSHOT$/)
        version = v.gsub(/-SNAPSHOT$/, "").split(/\./)
        if snapshot
          version[-1] = sprintf("%0#{version[-1].size}d", version[-1].to_i + 1) + '-SNAPSHOT'
        end
        version.join('.')
      }
      next_version = ENV['NEXT_VERSION'] if ENV['NEXT_VERSION']
      next_version = ENV['next_version'] if ENV['next_version']
      next_version = next_version.call(current_version) if Proc === next_version
      next_version
    end

    # Move the version to next and save the updated buildfile
    def update_buildfile
      buildfile = change_version { |version| # THIS_VERSION minus SNAPSHOT
        resolve_next_version(this_version) # THIS_VERSION
      }
      File.open(Rake.application.rakefile.to_s, 'w') { |file| file.write buildfile }
    end

    # Return the message to use to commit the buildfile with the next version
    def message
      version = extract_version
      msg = Release.commit_message || "Changed version number to #{version}"
      msg = msg.call(version) if Proc === msg
      msg
    end

    def update_version_to_next
      update_buildfile
    end
  end

  module Git  #:nodoc:
    module_function

    # :call-seq:
    #   git(*args)
    #
    # Executes a Git command and returns the output. Throws exception if the exit status
    # is not zero. For example:
    #   git 'commit'
    #   git 'remote', 'show', 'origin'
    def git(*args)
      cmd = "git #{args.shift} #{args.map { |arg| arg.inspect }.join(' ')}"
      output = `#{cmd}`
      fail "GIT command \"#{cmd}\" failed with status #{$?.exitstatus}\n#{output}" unless $?.exitstatus == 0
      return output
    end

    # Returns list of uncommited/untracked files as reported by git status.
    def uncommitted_files
      `git status`.scan(/^#(\t|\s{7})(\S.*)$/).map { |match| match.last.split.last }
    end

    # Commit the given file with a message.
    # The file has to be known to Git meaning that it has either to have been already committed in the past
    # or freshly added to the index. Otherwise it will fail.
    def commit(file, message)
      git 'commit', '-m', message, file
    end

    # Update the remote refs using local refs
    #
    # By default, the "remote" destination of the push is the the remote repo linked to the current branch.
    # The default remote branch is the current local branch.
    def push(remote_repo = remote, remote_branch = current_branch)
      git 'push', remote, current_branch
    end

    # Return the name of the remote repository whose branch the current local branch tracks,
    # or nil if none.
    def remote(branch = current_branch)
      remote = git('config', '--get', "branch.#{branch}.remote").to_s.strip
      remote if !remote.empty? && git('remote').include?(remote)
    end

    # Return the name of the current branch
    def current_branch
      git('branch')[/^\* (.*)$/, 1]
    end
  end

  module Perforce  #:nodoc:
    module_function

    # :call-seq:
    #   git(*args)
    #
    # Executes a Git command and returns the output. Throws exception if the exit status
    # is not zero. For example:
    #   git 'commit'
    #   git 'remote', 'show', 'origin'
    def p4(*args)

      port =  ENV['P4PORT']
      user =  ENV['P4USER']
      password = ENV['P4PASSWD']
      client = ENV['P4CLIENT']

      fail 'perforce release missing required P4PORT environment' unless port
      fail 'perforce release missing required P4USER environment' unless user
      fail 'perforce release missing required P4PASSWORD environment' unless password
      fail 'perforce release missing required P4CLIENT environment' unless client

      cmd = "p4 -p #{port} -u #{user} -P #{password} -c #{client} #{args.map { |arg| arg.inspect }.join(' ')}"
      output = `#{cmd}`
      fail "P4 command \"#{cmd}\" failed with status #{$?.exitstatus}\n#{output}" unless $?.exitstatus == 0
      return output
    end

    # Returns list of uncommited/untracked files as reported by git status.
    def uncommitted_files
      files = nil
      p4 (['change','-o']).each do |line|
        files << line.strip if files
        files = [] if line.start_with?('Files:')
      end
      files ||= []
    end

    # Commit the given file with a message.
    # The file has to be known to Git meaning that it has either to have been already committed in the past
    # or freshly added to the index. Otherwise it will fail.
    def commit(message)
      p4 'submit', '-d', message
    end
  end

  class PerforceRelease < Release
    class << self
      def applies_to?
        !File.exist? '.git/config' && ENV['P4PORT']
      end
    end

    def change_version
      Perforce.p4 'add', Rake.application.rakefile.to_s
      super
    end

    # Fails if one of these 2 conditions are not met:
    #    1. the repository is clean: no content staged or unstaged
    #    2. some remote repositories are defined but the current branch does not track any
    def check
      super
      uncommitted = Perforce.uncommitted_files
      fail "Uncommitted files violate the First Principle Of Release!\n#{uncommitted.join("\n")}" unless uncommitted.empty?
    end

    # Add a tag reference in .git/refs/tags and push it to the remote if any.
    # If a tag with the same name already exists it will get deleted (in both local and remote repositories).
    def tag_release(tag)
      unless this_version == extract_version
        puts "Committing buildfile with version number #{extract_version}"
        Perforce.p4 'edit', Rake.application.rakefile.to_s
        Perforce.commit message
      end
      puts "Tagging release #{tag}"
      Perforce.p4 'tag', '-l', tag, "//#{ENV['P4CLIENT']}/..."
    end

    def update_version_to_next
      Perforce.p4 'edit', Rake.application.rakefile.to_s
      super
      puts "Current version is now #{extract_version}"
      Perforce.commit message
    end
  end


  class GitRelease < Release
    class << self
      def applies_to?
        if File.exist? '.git/config'
          true
        else
          curr_pwd = Dir.pwd
          Dir.chdir('..') do
            return false if curr_pwd == Dir.pwd # Means going up one level is not possible.
            applies_to?
          end
        end
      end
    end

    # Fails if one of these 2 conditions are not met:
    #    1. the repository is clean: no content staged or unstaged
    #    2. some remote repositories are defined but the current branch does not track any
    def check
      super
      uncommitted = Git.uncommitted_files
      fail "Uncommitted files violate the First Principle Of Release!\n#{uncommitted.join("\n")}" unless uncommitted.empty?
      # fail "You are releasing from a local branch that does not track a remote!" unless Git.remote
    end

    # Add a tag reference in .git/refs/tags and push it to the remote if any.
    # If a tag with the same name already exists it will get deleted (in both local and remote repositories).
    def tag_release(tag)
      unless this_version == extract_version
        puts "Committing buildfile with version number #{extract_version}"
        Git.commit File.basename(Rake.application.rakefile.to_s), message
        Git.push if Git.remote
      end
      puts "Tagging release #{tag}"
      # Git.git 'tag', '-d', tag rescue nil
      Git.git 'push', Git.remote, ":refs/tags/#{tag}" rescue nil if Git.remote
      Git.git 'tag', '-f', '-a', tag, '-m', "[rake_release] Cutting release #{tag}"
      Git.git 'push', Git.remote, 'tag', tag if Git.remote
    end

    def update_version_to_next
      super
      puts "Current version is now #{extract_version}"
      Git.commit File.basename(Rake.application.rakefile.to_s), message
      Git.push if Git.remote
    end
  end

  Release.add GitRelease
  Release.add PerforceRelease

  desc 'Release by building, tagging, then incrementing the version number'
  task 'release', :options do |task, args|
    release = Release.find
    fail 'Unable to detect the Version Control System.' unless release
    release.make(args[:options])
  end

end

