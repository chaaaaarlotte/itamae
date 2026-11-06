require 'spec_helper'
require 'fakefs/spec_helpers'

module Itamae
  module Backend
    describe Base do
      include FakeFS::SpecHelpers

      class Klass < Itamae::Backend::Base
        def initialize(_, backend)
          @backend = backend
        end
      end

      let(:backend) { double('backend', send_file: nil, send_directory: nil) }
      let(:itamae_backend) { Klass.new('dummy', backend) }

      describe ".send_file" do
        context "the source file doesn't exist" do
          subject { itamae_backend.send_file("src", "dst") }
          it { expect{ subject }.to raise_error(Itamae::Backend::SourceNotExistError, "The file 'src' doesn't exist.") }
        end

        context "the source file exist, but it is not a regular file" do
          before { Dir.mkdir("src")  }
          subject { itamae_backend.send_file("src", "dst") }
          it { expect{ subject }.to raise_error(Itamae::Backend::SourceNotExistError, "'src' is not a file.") }
        end

        context "the source file is a regular file" do
          before { FileUtils.touch("src")  }
          subject { itamae_backend.send_file("src", "dst") }
          it { expect { subject }.not_to raise_error }
        end
      end

      describe ".send_directory" do
        context "the source directory doesn't exist" do
          subject { itamae_backend.send_directory("src", "dst") }
          it { expect{ subject }.to raise_error(Itamae::Backend::SourceNotExistError, "The directory 'src' doesn't exist.") }
        end

        context "the source directory exist, but it is not a directory" do
          before { FileUtils.touch("src")  }
          subject { itamae_backend.send_directory("src", "dst") }
          it { expect{ subject }.to raise_error(Itamae::Backend::SourceNotExistError, "'src' is not a directory.") }
        end

        context "the source directory is a directory" do
          before { Dir.mkdir("src")  }
          subject { itamae_backend.send_directory("src", "dst") }
          it { expect { subject }.not_to raise_error }
        end
      end
    end

    describe Ssh do

      describe "#ssh_options" do
        subject { ssh.send(:ssh_options) }

        let!(:ssh) { described_class.new(options) }
        let!(:host_name) { "example.com" }
        let!(:default_option) do
          opts = {}
          opts[:host_name] = nil
          opts.merge!(Net::SSH::Config.for(host_name))
          opts[:user] = opts[:user] || Etc.getlogin
          opts
        end

        context "with host option" do
          let(:options) { {host: host_name} }
          it { is_expected.to eq( default_option.merge({host_name: host_name}) ) }
        end

        context "with ssh_config option" do
          around do |example|
            Tempfile.create("ssh_config") do |temp|
              temp.write(<<EOF)
Host ex1
  HostName example.com
  User myname
  Port 10022
EOF
              temp.flush
              @ssh_config = temp.path
              example.run
            end
          end

          let(:options) { {host: "ex1", ssh_config: @ssh_config} }

          it { is_expected.to a_hash_including({host_name: "example.com", user: "myname", port: 10022}) }
        end
      end

      describe "#disable_sudo?" do
        subject { ssh.send(:disable_sudo?) }

        let!(:ssh) { described_class.new(options)}

        context "when sudo option is true" do
          let(:options) { {sudo: true} }
          it { is_expected.to eq(false) }
        end

        context "when sudo option is false" do
          let(:options) { {sudo: false} }
          it { is_expected.to eq(true) }
        end
      end

      describe "#receive_file" do
        let(:options) { {host: "example.com", user: "testuser", sudo: true} }
        let!(:ssh) { described_class.new(options) }
        let(:specinfra_backend) { ssh.instance_variable_get(:@backend) }
        let(:file_path) { "/home/testuser/test.txt" }
        let(:tmpdir) { '/tmp/itamae-read.1234567890' }
        let(:copy) { "#{tmpdir}/content" }
        let(:create_command) { 'mktemp -d /tmp/itamae-read.XXXXXXXXXX' }
        let(:prepare_command) do
          "cp -- #{file_path.shellescape} #{copy} && chmod 600 #{copy} && chown testuser #{copy} #{tmpdir}"
        end
        let(:cleanup_command) { "rm -rf #{tmpdir}" }
        let(:success) { Specinfra::CommandResult.new(exit_status: 0) }
        let(:failure) { Specinfra::CommandResult.new(exit_status: 1) }

        before do
          allow(specinfra_backend).to receive(:run_command).with(create_command).and_return(
            Specinfra::CommandResult.new(stdout: "#{tmpdir}\n", exit_status: 0)
          )
          allow(specinfra_backend).to receive(:run_command).with(prepare_command).and_return(success)
          allow(specinfra_backend).to receive(:run_command).with(cleanup_command).and_return(success)
          allow(specinfra_backend).to receive(:scp_download!).with(copy).and_return('file content')
        end

        it "sets permissions and ownership before downloading, then removes the copy" do
          expect(specinfra_backend).to receive(:run_command).with(prepare_command).ordered.and_return(success)
          expect(specinfra_backend).to receive(:scp_download!).with(copy).ordered.and_return('file content')
          expect(specinfra_backend).to receive(:run_command).with(cleanup_command).ordered.and_return(success)
          expect(ssh.receive_file(file_path)).to eq('file content')
        end

        it "raises without downloading or cleaning up when directory creation fails" do
          expect(specinfra_backend).to receive(:run_command).with(create_command).and_return(failure)
          expect(specinfra_backend).not_to receive(:scp_download!)
          expect(specinfra_backend).not_to receive(:run_command).with(cleanup_command)
          expect { ssh.receive_file(file_path) }.to raise_error(Itamae::Backend::CommandExecutionError)
        end

        it "raises and cleans up without downloading when preparing the copy fails" do
          expect(specinfra_backend).to receive(:run_command).with(prepare_command).and_return(failure)
          expect(specinfra_backend).not_to receive(:scp_download!)
          expect(specinfra_backend).to receive(:run_command).with(cleanup_command).and_return(success)
          expect { ssh.receive_file(file_path) }.to raise_error(Itamae::Backend::CommandExecutionError)
        end

        it "preserves the SCP exception and cleans up when downloading fails" do
          expect(specinfra_backend).to receive(:scp_download!).with(copy).and_raise(Net::SCP::Error)
          expect { ssh.receive_file(file_path) }.to raise_error(Net::SCP::Error)
          expect(specinfra_backend).to have_received(:run_command).with(cleanup_command)
        end

        it "downloads directly without creating a copy when sudo is disabled" do
          specinfra_backend.set_config(:disable_sudo, true)
          expect(specinfra_backend).not_to receive(:run_command)
          expect(specinfra_backend).to receive(:scp_download!).with(file_path, nil).and_return('file content')
          expect(ssh.receive_file(file_path)).to eq('file content')
        end

        it "downloads directly when a destination is specified" do
          expect(specinfra_backend).not_to receive(:run_command)
          expect(specinfra_backend).to receive(:scp_download!).with(file_path, '/tmp/dst')
          ssh.receive_file(file_path, '/tmp/dst')
        end
      end
    end
  end
end
