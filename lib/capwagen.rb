
require 'capwagen/version'

module Capwagen
  def self.load_into(configuration)
    configuration.load do
      set :drush_cmd, 'drush'

      set :deploy_via, :capwagen_local_build

      set :capwagen_tmp_basename, 'capwagen'
      set :kraftwagen_environment, 'production'

      set :normalize_asset_timestamps, false

      set :drupal_site_name, 'default'
      set(:shared_files) {
        ["sites/#{drupal_site_name}/settings.php",
         "sites/#{drupal_site_name}/settings.local.php"]
      }
      set(:shared_dirs) {
        ["sites/#{drupal_site_name}/files"]
      }

      namespace :deploy do
        # We override the default update task, because we need to add our own 
        # routines between the defaults
        task :update do
          transaction do
            update_code
            find_and_execute_task("drupal:offline")
            create_symlink
            find_and_execute_task("kraftwagen:update")
            find_and_execute_task("drupal:online")
          end
        end

        task :install do
          transaction do
            update_code
            create_symlink
            find_and_execute_task("kraftwagen:install")
          end
        end

        # We override the default finalize update task, because our logic for 
        # filling projects with the correct symlinks, is completely different from
        # Rails projects.
        task :finalize_update, :except => { :no_release => true } do
          escaped_release = latest_release.to_s.shellescape

          commands = []
          commands << "chmod -R -- g+w #{escaped_release}" if fetch(:group_writable, true)

          # mkdir -p is making sure that the directories are there for some SCM's that don't
          # save empty folders
          (shared_files + shared_dirs).map do |dir|
            d = dir.shellescape
            if (d.rindex('/')) then
              commands += ["rm -rf #{escaped_release}/#{d}",
                           "mkdir -p #{escaped_release}/#{dir.slice(0..(dir.rindex('/'))).shellescape}"]
            else
              commands << "rm -rf #{escaped_release}/#{d}"
            end
            commands << "ln -s #{shared_path}/#{dir.split('/').last.shellescape} #{escaped_release}/#{d}"
          end

          run commands.join(' && ') if commands.any?
        end

        task :setup, :except => { :no_release => true } do
          dirs = [deploy_to, releases_path, shared_path]
          dirs += shared_dirs.map { |d| File.join(shared_path, d.split('/').last) }
          run "#{try_sudo} mkdir -p #{dirs.join(' ')}"
          run "#{try_sudo} chmod g+w #{dirs.join(' ')}" if fetch(:group_writable, true)
        end
      end

      # The Drupal namespace contains the commands for Drupal that is not specific
      # to the Kraftwagen update process
      namespace :drupal do
        task :cache_clear, :except => { :no_release => true }, :only => { :primary => true } do
          run "cd #{latest_release} && #{drush_cmd} cache-clear all"
        end
        task :cache_clear_drush do
          run "cd #{latest_release} && #{drush_cmd} cache-clear drush"
        end
        task :offline, :except => { :no_release => true }, :only => { :primary => true } do
          run "cd #{latest_release} && #{drush_cmd} variable-set maintenance_mode 1 --yes"
          cache_clear
        end
        task :online, :except => { :no_release => true }, :only => { :primary => true } do
          run "cd #{latest_release} && #{drush_cmd} variable-set maintenance_mode 0 --yes"
          cache_clear
        end
      end

      # The Kraftwagen namespace contains the Kraftwagen update process
      namespace :kraftwagen do
        task :install do
          initialize_database
          find_and_execute_task("drupal:cache_clear")
          update
        end

        task :update do
          apply_module_dependencies
          updatedb
          find_and_execute_task("drupal:cache_clear_drush")
          features_revert
          find_and_execute_task("drupal:cache_clear")
          manifests
          find_and_execute_task("drupal:cache_clear")
        end

        task :initialize_database do
          run "cd #{latest_release} && #{drush_cmd} site-install $(#{drush_cmd} kw-env-info --pipe) --yes"
        end
        task :apply_module_dependencies do
          run "cd #{latest_release} && #{drush_cmd} kw-apply-module-dependencies #{kraftwagen_environment}"
        end
        task :updatedb do
          run "cd #{latest_release} && #{drush_cmd} updatedb --yes"
        end
        task :features_revert do
          run "cd #{latest_release} && #{drush_cmd} features-revert-all --yes"
        end
        task :manifests do
          run "cd #{latest_release} && #{drush_cmd} kw-manifests #{kraftwagen_environment}"
        end
      end

    end
  end
end

Capwagen.load_into(Capistrano::Configuration.instance)
