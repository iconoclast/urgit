require File.expand_path(File.dirname(__FILE__) + '/spec_helper')
require 'urgit/config'

describe Urgit::Config do
  dir = File.expand_path(File.dirname(__FILE__) + '/fixtures')
  subject { Urgit::Config.new(dir) }
  let(:settings) { subject.options_hash }
  let(:options) { subject.options }

  context "when parsing from a file" do

    it "returns the configuration as a nested hash" do
      settings.should have_key('color')
      settings.should_not have_key('color.diff')
      settings['color'].should have_key('diff')
      settings['branch']['master'].should have(2).keys
      settings['rerere']['enabled'].should equal(true)
    end

    it "returns the configuration in dotted-string form" do
      pending "dotted-string methods need to be implemented" do
        options['color.ui'].should == 'auto'
        options['color.diff.meta'].should == 'cyan'
        it 'treats section and variable names as case-insensitive' do
          # note: sub-section names might or might not be case-sensitive
          options['Branch.master.Remote'].should == 'origin'
        end
      end
    end

    it "writes changes back to the config file" do
      filename = subject.instance_variable_get(:@config_file_path)
      file = StringIO.new
      File.should_receive(:open).with(filename, "wb").and_yield(file)

      settings['core']['new-key'] = 'Test value'
      subject.save

      file.string.should =~ /\s+new-key = Test value/
    end
  end

  describe "working with remotes" do
    let(:remote_hash) { {:name => 'test-remote', :url => '/tmp/test-remote'} }

    it "appends new remotes to the configuration" do
      expect { subject.remotes << remote_hash }.to change{ subject.remotes.count }.by(1)
      settings['remote']['test-remote']['url'].should == remote_hash[:url]
    end
  end

end
