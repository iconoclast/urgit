
# More info at https://github.com/guard/guard#readme
# gems needed by each guard section are in the comments

# gem 'guard-bundler'
guard 'bundler' do
  watch('Gemfile')
  watch(/^.+\.gemspec/)
end

# automatic continuous test results during development
group 'test' do

  # guard 'spork'
  # this needs further testing, as it may be problematic under jruby
  # a nailgun based solution may be another alternative.

  # gem 'guard-rspec'
  guard 'rspec', :version => 2 do
    watch(%r{^spec/.+_spec\.rb$})
    watch(%r{^lib/(.+)\.rb$})     { |m| "spec/lib/#{m[1]}_spec.rb" }
    watch('spec/spec_helper.rb') { "spec" }
  end

  # gem 'guard-cucumber'
  guard 'cucumber', :cli => '--profile guard', :keep_failed => true do
    watch(%r{^features/.+\.feature$})
    watch(%r{^features/support/.+\.rb$})          { 'features' }
    watch(%r{^features/step_definitions/(.+)_steps\.rb$}) { |m| Dir[File.join("**/#{m[1]}.feature")][0] || 'features' }
  end
end
