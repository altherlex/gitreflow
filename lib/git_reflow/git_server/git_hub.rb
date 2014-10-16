require 'github_api'
require 'git_reflow/git_helpers'

module GitReflow
  module GitServer
    class GitHub < Base
      include GitHelpers

      attr_accessor :connection

      @project_only     = false
      @using_enterprise = false
      @git_config_group = 'github'.freeze

      def initialize(config_options = {})
        @project_only     = !!config_options.delete(:project_only)
        @using_enterprise = !!config_options.delete(:enterprise)

        gh_site_url     = self.class.site_url
        gh_api_endpoint = self.class.api_endpoint
        
        if @using_enterprise
          gh_site_url     = ask("Please enter your Enterprise site URL (e.g. https://github.company.com):")
          gh_api_endpoint = ask("Please enter your Enterprise API endpoint (e.g. https://github.company.com/api/v3):")
        end

        self.class.site_url     = gh_site_url
        self.class.api_endpoint = gh_api_endpoint

        if @project_only
          GitReflow::Config.set('reflow.git-server', 'GitHub', local: true)
        else
          GitReflow::Config.set('reflow.git-server', 'GitHub')
        end
      end

      def authenticate(options = {silent: false})
        if connection
          unless options[:silent]
            puts "Your GitHub account was already setup with: "
            puts "\tUser Name: #{self.class.user}"
            puts "\tEndpoint: #{self.class.api_endpoint}"
          end
        else
          begin
            gh_user     = ask("Please enter your GitHub username: ")
            gh_password = ask("Please enter your GitHub password (we do NOT store this): ") { |q| q.echo = false }

            @connection = ::Github.new do |config|
              config.basic_auth = "#{gh_user}:#{gh_password}"
              config.endpoint   = GitServer::GitHub.api_endpoint
              config.site       = GitServer::GitHub.site_url
              config.adapter    = :net_http
              config.ssl        = {:verify => false}
            end

            previous_authorizations = @connection.oauth.all.select {|auth| auth.note == "git-reflow (#{run('hostname', loud: false).strip})" }
            if previous_authorizations.any?
              authorization = previous_authorizations.last
            else
              authorization = @connection.oauth.create scopes: ['repo'], note: "git-reflow (#{run('hostname', loud: false).strip})"
            end

            oauth_token   = authorization.token

            self.class.oauth_token = oauth_token
            puts "\nYour GitHub account was successfully setup!"

          rescue StandardError => e
            puts "\nInvalid username or password: #{e.inspect}"
          else
            puts "\nYour GitHub account was successfully setup!"
          end
        end

        @connection
      end

      def create_pull_request(options = {})
        pull_request = connection.pull_requests.create(remote_user, remote_repo_name,
                                                       title: options[:title],
                                                       body:  options[:body],
                                                       head:  "#{remote_user}:#{current_branch}",
                                                       base:  options[:base])
      end

      def find_pull_request(options = {})
        connection.pull_requests.all(remote_user, remote_repo_name, base: options[:to], head: "#{remote_user}:#{options[:from]}", :state => 'open').first
      end

      def self.connection
        if self.oauth_token.length > 0
          @connection ||= ::Github.new do |config|
            config.oauth_token = GitServer::GitHub.oauth_token
            config.endpoint    = GitServer::GitHub.api_endpoint
            config.site        = GitServer::GitHub.site_url
          end
        end
      end

      def connection
        @connection ||= self.class.connection
      end

      def pull_request_comments(pull_request)
        comments        = connection.issues.comments.all        remote_user, remote_repo_name, number: pull_request.number
        review_comments = connection.pull_requests.comments.all remote_user, remote_repo_name, number: pull_request.number

        review_comments.to_a + comments.to_a
      end

      def get_build_status sha
        connection.repos.statuses.all(remote_user, remote_repo_name, sha).first
      end

      def colorized_build_description status
        colorized_statuses = { pending: :yellow, success: :green, error: :red, failure: :red }
        status.description.colorize( colorized_statuses[status.state.to_sym] )
      end

      def find_authors_of_open_pull_request_comments(pull_request)
        # first we'll gather all the authors that have commented on the pull request
        pull_last_committed_at = get_commited_time(pull_request.head.sha)
        comment_authors        = comment_authors_for_pull_request(pull_request)
        lgtm_authors           = comment_authors_for_pull_request(pull_request, :with => LGTM, :after => pull_last_committed_at)

        comment_authors - lgtm_authors
      end

      def comment_authors_for_pull_request(pull_request, options = {})
        all_comments    = pull_request_comments(pull_request)
        comment_authors = []

        all_comments.each do |comment|
          next if options[:after] and Time.parse(comment.created_at) < options[:after]
          if (options[:with].nil? or comment[:body] =~ options[:with])
            comment_authors |= [comment.user.login]
          end
        end

        # remove the current user from the list to check
        comment_authors -= [self.class.user]
      end

      def get_commited_time(commit_sha)
        last_commit = connection.repos.commits.find remote_user, remote_repo_name, commit_sha
        Time.parse last_commit.commit.author[:date]
      end

    end
  end
end
