package App::Gitc::Config;
use strict;
use warnings;

use YAML ();

=head1 Synopsis

Configuration file for gitc

=head1 Description

Contains a set of hashref configurations for each project.


The '%config' hash contains the configuration as follows...

repo_base: This is the git username@server that contains the repo
projects: each top level key is the repo/project name (matches repo name 'gitc setup cbs-taxsys' looks up the 'cbs-taxsys' entry)
          '_default' is a special case containing the base/default configuration
          the name is case sensitive and contains a hashref with the following options:
    default_its: Default ITS (issue tracking system) to use (can be 'eventum' or 'jira')
    eventum_uri: URI used to access the Eventum API (Setting this to 'undef' prevents default/automatic API access for eventum style changesets)
    jira_uri: URI used to access the JIRA API (Setting this to 'undef' prevents default/automatic API access for JIRA style changesets)
    open onto: This is the base branch used when creating new changesets (i.e. 'master' means branches start from the master HEAD)

    eventum_statuses: For Eventum transitions; Contains a set of hashrefs, top level key is the 'command' (i.e. for gitc open XXX, the top level is 'open')
                  The 'promote' command is special and has another level for the target (i.e. gitc promote stage, looks at 'promote' => { .. 'stage' => {...} })
                  Each command may have the following options:
        from: A regex of the acceptable starting ITS status/state (use '.*' for any, use '|' to split different states as in 'in test|ready for staging')
        to: The target state/status
        block: An ARRAYREF of states/status that prevent the command from running (i.e. 'gitc open' fails if the initial state is 'closed', 'completed' or 'in production')

    jira_statuses: For JIRA transitions; Contains a set of hashrefs, top level key is the 'command' (i.e. for gitc open XXX, the top level is 'open')
                  The 'promote' command is special and has another level for the target (i.e. gitc promote stage, looks at 'promote' => { .. 'stage' => {...} })
                  Each command may have the following options:
        from: A regex of the acceptable starting ITS status/state (use '.*' for any, use '|' to split different states as in 'in test|ready for staging')
        to: The target state/status
        block: An ARRAYREF of states/status that prevent the command from running (i.e. 'gitc open' fails if the initial state is 'closed', 'completed' or 'in production')
        flag: This is used by the JIRA ITS to prefix the message with an icon (i.e. '(*)' adds a star icon) [see JIRA docs for available icons]

=cut

my %default_config = (
    'repo_base'        => 'git@example',
    'default_its'      => 'eventum',
    'eventum_uri'      => 'https://eventum.example.com',
    'jira_uri'         => 'https://example.atlassian.net/',
    'eventum_statuses' => {
        open => {
            from => '.*',
            to   => 'in progress',
            block => [ 'closed', 'completed', 'in production' ],
        },
        edit => {
            from => '.*',
            to   => 'in progress',
        },
        submit => {
            from => 'in progress|failed',
            to   => 'pending review',
        },
        fail => {
            from => 'pending review',
            to   => 'failed',
        },
        pass => {
            from => 'pending review',
            to   => 'merged',
        },
        promote => {
            test => {
                from => 'merged',
                to   => 'in test',
            },
            stage => {
                from => 'in test|ready for staging',
                to   => 'in stage',
            },
            prod => {
                from => 'in stage|ready for release',
                to   => 'CLOSE',
            },
        },
    },
    'jira_statuses' => {
        open => {
            from => '.*',
            to   => 'In Progress',
            flag => '(*)', 
            block => [ 'Closed', 'Completed', 'Released' ],
        },
        edit => {
            from => '.*',
            to   => 'In Progress',
            flag => '(*)',
        },
        submit => {
            from => 'In Progress|Failed|Info Needed',
            to   => 'Work Pending Review',
            flag => '(?)',
        },
        fail => {
            from => 'Work Pending Review',
            to   => 'Failed',
            flag => '(n)',
        },
        pass => {
            from => 'Work Pending Review',
            to   => 'Work Reviewed',
            flag => '(y)',
        },
        promote => {
            test => {
                from => 'Work Reviewed',
                to   => 'In Test',
                flag => '(+)',
            },
            stage => {
                from => 'In Test|Passed in Test',
                to   => 'In Stage',
                flag => '(+)',
            },
            prod => {
                from => 'In Stage|Passed in Stage',
                to   => 'Ready for Release',
                flag => '(+)',
            },
        },
    },
    'open onto' => 'prod',
);

my $config;

my @GITC_CONFIG_SEARCH_PATH = (
    "/etc/gitc/gitc.config",
    '$PROJECT/.gitc/gitc.config',
    "$ENV{USER}/.gitc/gitc.config",
);

sub load_config {
    my $project_name = shift;

    # Use the cached config if available
    return $config->{ $project_name } 
        if defined $config->{ $project_name };

    # Configuration is not loaded. Load it.

    # Add any custom search paths specified in the environment
    my @extra_paths;
    if (defined $ENV{GITC_CONFIG}) {

        # Seems like this should be part of standard perl somewhere...
        my $path_sep = $^O =~ /^(?:MSWin32|os2|dos)$/ ? ';'
                     :                                  ':';

        @extra_paths = split /$path_sep/, $ENV{GITC_CONFIG};
    }

    # Start empty
    my %local_default_config;
    my %local_project_config;

    for my $config_path (@GITC_CONFIG_SEARCH_PATH, @extra_paths) {

        # The $PROJECT config can only be read when the current project matches
        # the project for which we want configuration (i.e., most cases other
        # than when gitc-setup loads configuration).
        my $is_project_config = 0;
        if ($config_path =~ /^\$PROJECT\b/ and $project_name eq App::Gitc::Util::project_name()) {
            my $project_root = App::Gitc::Util::project_root();
            $config_path =~ s/^\$PROJECT\b/$project_root/;
            $is_project_config++;
        }

        # If the configuration exists, load it and merge
        if (-f $config_path) {
            my $this_config = YAML::LoadFile($config_path);

            # _default config in $PROJECT makes no sense at all
            my $default_config = $this_config->{_default};
            if ($is_project_config and defined $this_config->{_default}) {
                warn "Ignoring _default configuration in $config_path.\n";
                $default_config = {};
            }

            $default_config = {} unless defined $default_config;
            
            # Make sure to let the user know if $PROJECT config is wrong
            my $project_config = $this_config->{ $project_name };
            if ($is_project_config and not defined $this_config->{ $project_name }) {
                warn "Missing $project_name configuration in $config_path.\n";
                $project_config = {};
            }

            $project_config = {} unless defined $project_config;

            # Merge defaults together
            %local_default_config = (
                %local_default_config,
                %$default_config,
            );

            # Merge per-project config together
            %local_project_config = (
                %local_project_config,
                %$project_config,
            );
        }
    }

    # Apply the defaults last of all
    %local_project_config = (
        %local_default_config,
        %local_project_config,
    );

    # Configuration of last resort...
    $config->{_default} = \%local_default_config;

    return $config->{ $project_name } = \%local_project_ocnfig;
}

sub project_config {
    my $name = shift;

    my $project_config = load_config($name) if defined $name;
    return $project_config if defined $project_config;
    return $config->{_default};
}

=head1 AUTHOR

Grant Street Group <F<developers@grantstreet.com>>

=head1 COPYRIGHT AND LICENSE

    Copyright 2012 Grant Street Group, All Rights Reserved.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as
    published by the Free Software Foundation, either version 3 of the
    License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.

=cut

1;
