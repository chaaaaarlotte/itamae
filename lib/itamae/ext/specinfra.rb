# TODO: Send patches to Specinfra

module Specinfra
  module Backend
    class Base
      def receive_file(from, to = nil)
        raise NotImplementedError
      end
    end

    class Exec < Base
      def receive_file(from, to = nil)
        if to
          FileUtils.cp(from, to)
        else
          ::File.read(from)
        end
      end
    end

    class Docker < Exec
      def receive_file(from, to = nil)
        if to
          send_file(from, to)
        else
          run_command("cat #{from}").stdout
        end
      end
    end

    class Ssh < Exec
      def receive_file(from, to = nil)
        return scp_download!(from, to) if to || !sudo?

        # Keep the copy private until it can be read by the SSH login user.
        tmpdir = run_command!("mktemp -d /tmp/itamae-read.XXXXXXXXXX").stdout.strip
        begin
          copy = File.join(tmpdir, 'content')
          user = get_config(:ssh_options)[:user].shellescape
          run_command!("cp -- #{from.shellescape} #{copy.shellescape} && " \
                       "chmod 600 #{copy.shellescape} && " \
                       "chown #{user} #{copy.shellescape} #{tmpdir.shellescape}")
          scp_download!(copy)
        ensure
          run_command!("rm -rf #{tmpdir.shellescape}")
        end
      end

      private

      def run_command!(command)
        result = run_command(command)
        unless result.success?
          raise Itamae::Backend::CommandExecutionError, "Command #{command.inspect} failed (exit status: #{result.exit_status})"
        end
        result
      end

      def scp_download!(from, to, opt={})
        if get_config(:scp).nil?
          set_config(:scp, create_scp)
        end

        scp = get_config(:scp)
        scp.download!(from, to, opt)
      end
    end
  end
end

