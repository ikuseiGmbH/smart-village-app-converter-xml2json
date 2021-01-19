# Use this file to easily define all of your cron jobs.
#
# It's helpful, but not entirely necessary to understand cron before proceeding.
# http://en.wikipedia.org/wiki/Cron

# Example:
#
set :output, "/var/log/cron.log"
#
# every 2.hours do
#   command "/usr/bin/some_great_command"
#   runner "MyModel.some_method"
#   rake "some:great:rake:task"
# end
#
# set :environment, ENV['RAILS_ENV']
# env :PATH, ENV['PATH']
# env :BUNDLE_PATH, '/usr/local/bundle'
# env :GEM_HOME, '/usr/local/bundle'
# env :BUNDLE_APP_CONFIG, '/usr/local/bundle'
set :job_template, "/bin/sh -l -c ':job'"
set :environment, ENV["RAILS_ENV"]

every 1.day, at: "00:05 am" do
  runner "Importer.load_data(:poi)"
end

every 1.day, at: "00:30 am" do
  runner "Importer.load_data(:event)"
end

every 1.day, at: "01:05 am" do
  runner "Importer.parse_data(:poi)"
end

every 1.day, at: "03:05 am" do
  runner "Importer.parse_data(:event)"
end

every 1.day, at: "05:05 am" do
  runner "Importer.send_data(:poi)"
  runner "Importer.send_data(:event)"
end

# Learn more: http://github.com/javan/whenever
