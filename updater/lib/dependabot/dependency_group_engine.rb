# frozen_string_literal: true

require "dependabot/dependency_group"

# This class implements our strategy for keeping track of and matching dependency
# groups that are defined by users in their dependabot config file.
#
# We instantiate the DependencyGroupEngine after parsing dependencies, configuring
# any groups from the job's configuration before assigning the dependency list to
# the groups.
#
# We permit dependencies to be in more than one group and also track those which
# have zero matches so they may be updated individuall.
#
# **Note:** This is currently an experimental feature which is not supported
#           in the service or as an integration point.
#
module Dependabot
  class DependencyGroupEngine
    class ConfigurationError < StandardError; end

    def self.from_job_config(job:)
      groups = job.dependency_groups.map do |group|
        Dependabot::DependencyGroup.new(name: group["name"], rules: group["rules"])
      end

      new(dependency_groups: groups)
    end

    attr_reader :dependency_groups, :groups_calculated

    def find_group(name:)
      dependency_groups.find { |group| group.name == name }
    end

    def assign_to_groups!(dependencies:)
      raise ConfigurationError, "dependency groups have already been configured!" if @groups_calculated

      if dependency_groups.any?
        dependencies.each do |dependency|
          matched_groups = @dependency_groups.each_with_object([]) do |group, matches|
            next unless group.contains?(dependency)

            group.dependencies.push(dependency)
            matches << group
          end

          # If we had no matches, collect the dependency as ungrouped
          @ungrouped_dependencies << dependency if matched_groups.empty?
        end
      else
        @ungrouped_dependencies = dependencies
      end

      validate_groups
      @groups_calculated = true
    end

    def ungrouped_dependencies
      @ungrouped_dependencies + dependencies_with_ungrouped_semvar_levels
    end

    private

    def initialize(dependency_groups:)
      @dependency_groups = dependency_groups
      @ungrouped_dependencies = []
      @groups_calculated = false
    end

    def validate_groups
      empty_groups = dependency_groups.select { |group| group.dependencies.empty? }
      warn_misconfigured_groups(empty_groups) if empty_groups.any?
    end

    def warn_misconfigured_groups(groups)
      Dependabot.logger.warn <<~WARN
        Please check your configuration as there are groups no dependencies match:
        #{groups.map { |g| "- #{g.name}" }.join("\n")}

        This can happen if:
        - the group's 'pattern' rules are mispelled
        - your configuration's 'allow' rules do not permit any of the dependencies that match the group
        - the dependencies that match the group rules have been removed from your project
      WARN
    end

    # TODO: Limit the dependency set to those we know have passed-over updates
    #
    # This will make a second update attempt on every dependency in any groups
    # which do not permit highest version avaliable upgrades.
    #
    # We can be smarter about this since the versions available will need
    # to be checked at least once prior to this set being evaluated.
    #
    # It will require us to start evaluating the DependencyGroup inside the
    # UpdaterChecker and expose methods for the highest resolvable version
    # both with and without the group's ignore rules.
    #
    # I'd rather ship this change separately once we've proved this run schema
    # works as expected in terms of creating both group and single PRs which do
    # not interfere with each other.
    def dependencies_with_ungrouped_semvar_levels
      dependency_groups.reject(&:targets_highest_versions_possible?).map(&:dependencies).flatten
    end
  end
end
