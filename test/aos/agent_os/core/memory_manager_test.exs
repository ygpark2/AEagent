defmodule AOS.AgentOS.Core.MemoryManagerTest do
  use AOS.DataCase

  alias AOS.AgentOS.Core.MemoryManager
  alias AOS.AgentOS.Core.MemoryStore
  alias AOS.AgentOS.Core.NodeRegistry
  alias AOS.AgentOS.Evolution.StrategyRegistry

  import Mock

  describe "MemoryManager" do
    test "module exists" do
      assert is_list(MemoryManager.module_info())
    end

    test "handle_info :cleanup" do
      with_mock MemoryStore,
        delete_failed_executions_before: fn _ -> 1 end,
        clear_success_logs_before: fn _ -> 2 end,
        successful_count_for_domain: fn _ -> 100 end,
        delete_oldest_successes_for_domain: fn _, _ -> 3 end do
        with_mock NodeRegistry,
          all_domains: fn -> ["test_domain"] end do
          with_mock StrategyRegistry,
            prune: fn -> %{archived: 4} end do
            with_mock AOS.AgentOS.Config, [:passthrough], domain_success_cap: fn -> 50 end do
              MemoryManager.handle_info(:cleanup, %{})
              assert called(MemoryStore.delete_failed_executions_before(:_))
              assert called(MemoryStore.clear_success_logs_before(:_))
              assert called(MemoryStore.successful_count_for_domain("test_domain"))
              assert called(MemoryStore.delete_oldest_successes_for_domain("test_domain", 50))
              assert called(StrategyRegistry.prune())
            end
          end
        end
      end
    end
  end
end
