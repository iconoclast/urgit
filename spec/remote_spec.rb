require File.expand_path(File.dirname(__FILE__) + '/spec_helper')
require 'urgit/remote'

describe Urgit::Remote do
  before(:each) do
    @remote = Urgit::Remote.new(:name => 'remote-test', :url => '/some/path')
  end

  it { should respond_to(:name) }
  it { should respond_to(:url) }
  it { should respond_to(:head) }
  it { should respond_to(:fetch) }
  it { should respond_to(:push) }

  describe "#branches" do
    it { should have(0).branches }
    pending "some useful branch testing needed"
  end

end
