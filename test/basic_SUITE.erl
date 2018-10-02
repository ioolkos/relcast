-module(basic_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0
]).

-export([
    basic/1,
    stop_resume/1,
    defer/1,
    defer_stop_resume/1,
    epochs/1,
    epochs_gc/1
]).

all() ->
    [basic, stop_resume, defer, defer_stop_resume, epochs, epochs_gc].

basic(_Config) ->
    Actors = lists:seq(1, 3),
    {ok, RC1} = relcast:start(1, Actors, test_handler, [1], [{data_dir, "data1"}]),
    not_found = relcast:take(2, RC1),
    {false, _} = relcast:command(is_done, RC1),
    {ok, RC1_2} = relcast:deliver(<<"hello">>, 2, RC1),
    {true, _} = relcast:command(is_done, RC1_2),
    {ok, Ref, <<"ehlo">>, RC1_3} = relcast:take(2, RC1_2),
    %% same result if we take() again for this actor
    {ok, Ref, <<"ehlo">>, RC1_3} = relcast:take(2, RC1_3),
    %% ack it
    {ok, RC1_4} = relcast:ack(2, Ref, RC1_3),
    %% check it's gone
    {ok, Ref2, <<"hai">>, RC1_5} = relcast:take(2, RC1_4),
    %% take for actor 3
    {ok, Ref3, <<"hai">>, RC1_6} = relcast:take(3, RC1_5),
    %% ack with the wrong ref
    {ok, RC1_7} = relcast:ack(3, Ref, RC1_6),
    %% actor 3 still has pending data
    {ok, Ref3, <<"hai">>, RC1_8} = relcast:take(3, RC1_7),
    %% ack both of the outstanding messages
    {ok, RC1_9} = relcast:ack(2, Ref2, RC1_8),
    not_found = relcast:take(2, RC1_9),
    {ok, RC1_10} = relcast:ack(3, Ref3, RC1_9),
    not_found = relcast:take(2, RC1_10),
    relcast:stop(normal, RC1_10),
    ok.

stop_resume(_Config) ->
    Actors = lists:seq(1, 3),
    {ok, RC1} = relcast:start(1, Actors, test_handler, [1], [{data_dir, "data2"}]),
    not_found = relcast:take(2, RC1),
    {false, _} = relcast:command(is_done, RC1),
    {ok, RC1_2} = relcast:deliver(<<"hello">>, 2, RC1),
    {true, _} = relcast:command(is_done, RC1_2),
    {_, [], Outbound} = relcast:status(RC1_2),
    [<<"ehlo">>, <<"hai">>] = maps:get(2, Outbound),
    [<<"hai">>] = maps:get(3, Outbound),
    {ok, Ref, <<"ehlo">>, RC1_3} = relcast:take(2, RC1_2),
    %% same result if we take() again for this actor
    {ok, Ref, <<"ehlo">>, RC1_3} = relcast:take(2, RC1_3),
    %% ack it
    {ok, RC1_3a} = relcast:ack(2, Ref, RC1_3),
    relcast:stop(normal, RC1_3a),
    {ok, RC1_4} = relcast:start(1, Actors, test_handler, [1], [{data_dir, "data2"}]),
    %% check it's gone
    {ok, Ref2, <<"hai">>, RC1_5} = relcast:take(2, RC1_4),
    %% take for actor 3
    {ok, Ref3, <<"hai">>, RC1_6} = relcast:take(3, RC1_5),
    %% ack with the wrong ref
    {ok, RC1_7} = relcast:ack(3, Ref, RC1_6),
    %% actor 3 still has pending data
    {ok, Ref3, <<"hai">>, RC1_7a} = relcast:take(3, RC1_7),
    relcast:stop(normal, RC1_7a),
    {ok, RC1_8} = relcast:start(1, Actors, test_handler, [1], [{data_dir, "data2"}]),
    %% ack both of the outstanding messages
    {ok, RC1_9} = relcast:ack(2, Ref2, RC1_8),
    %% we lost the ack, so the message is still in-queue
    {ok, Ref4, <<"hai">>, RC1_10} = relcast:take(2, RC1_9),
    {ok, RC1_11} = relcast:ack(3, Ref3, RC1_10),
    {ok, Ref5, <<"hai">>, RC1_12} = relcast:take(2, RC1_11),
    %% ack both of the outstanding messages again
    {ok, RC1_13} = relcast:ack(2, Ref4, RC1_12),
    not_found = relcast:take(2, RC1_13),
    {ok, RC1_14} = relcast:ack(3, Ref5, RC1_13),
    not_found = relcast:take(2, RC1_14),
    relcast:stop(normal, RC1_14),
    ok.

defer(_Config) ->
    Actors = lists:seq(1, 3),
    {ok, RC1} = relcast:start(1, Actors, test_handler, [1], [{data_dir, "data3"}]),
    %% try to put an entry in the seq map, it will be deferred because the
    %% relcast is in round 0
    {defer, RC1_2} = relcast:deliver(<<"seq", 1:8/integer>>, 2, RC1),
    {_, [{2, <<"seq", 1:8/integer>>}], Outbound} = relcast:status(RC1_2),
    0 = maps:size(Outbound),
    {0, _} = relcast:command(round, RC1_2),
    {#{}, _} = relcast:command(seqmap, RC1_2),
    {ok, RC1_3} = relcast:command(next_round, RC1_2),
    {Map, _} = relcast:command(seqmap, RC1_3),
    [{2, 1}] = maps:to_list(Map),
    %% queue up several seq messages. all are valid but only the first can apply
    %% right now
    {ok, RC1_4} = relcast:deliver(<<"seq", 1:8/integer>>, 3, RC1_3),
    {defer, RC1_5} = relcast:deliver(<<"seq", 2:8/integer>>, 3, RC1_4),
    {defer, RC1_5a} = relcast:deliver(<<"seq", 3:8/integer>>, 3, RC1_5),
    %% also attempt to queue a sequence number for 2 with a break, so it's not
    %% valid - this should not be deferred
    {ok, RC1_6} = relcast:deliver(<<"seq", 3:8/integer>>, 2, RC1_5a),
    {Map2, _} = relcast:command(seqmap, RC1_6),
    [{2, 1}, {3, 1}] = lists:sort(maps:to_list(Map2)),
    %% increment the round, the seqmap should increment for 3
    {ok, RC1_7} = relcast:command(next_round, RC1_6),
    {Map3, _} = relcast:command(seqmap, RC1_7),
    [{2, 1}, {3, 2}] = lists:sort(maps:to_list(Map3)),
    %% increment it again, it should increment seqmap for 3 again
    {ok, RC1_8} = relcast:command(next_round, RC1_7),
    {Map4, _} = relcast:command(seqmap, RC1_8),
    [{2, 1}, {3, 3}] = lists:sort(maps:to_list(Map4)),
    relcast:stop(normal, RC1_8),
    ok.

defer_stop_resume(_Config) ->
    Actors = lists:seq(1, 3),
    {ok, RC1} = relcast:start(1, Actors, test_handler, [1], [{data_dir, "data4"}]),
    %% try to put an entry in the seq map, it will be deferred because the
    %% relcast is in round 0
    {defer, RC1_2} = relcast:deliver(<<"seq", 1:8/integer>>, 2, RC1),
    {0, _} = relcast:command(round, RC1_2),
    {#{}, _} = relcast:command(seqmap, RC1_2),
    {ok, RC1_3} = relcast:command(next_round, RC1_2),
    {Map, _} = relcast:command(seqmap, RC1_3),
    [{2, 1}] = maps:to_list(Map),
    %% queue up several seq messages. all are valid but only the first can apply
    %% right now
    {ok, RC1_4} = relcast:deliver(<<"seq", 1:8/integer>>, 3, RC1_3),
    {defer, RC1_5} = relcast:deliver(<<"seq", 2:8/integer>>, 3, RC1_4),
    {defer, RC1_5a} = relcast:deliver(<<"seq", 3:8/integer>>, 3, RC1_5),
    %% stop and resume the relcast here to make sure we recover all our states
    %% correctly
    relcast:stop(normal, RC1_5a),
    {ok, RC1_5b} = relcast:start(1, Actors, test_handler, [1], [{data_dir, "data4"}]),
    %% also attempt to queue a sequence number for 2 with a break, so it's not
    %% valid - this should not be deferred
    {ok, RC1_6} = relcast:deliver(<<"seq", 3:8/integer>>, 2, RC1_5b),
    {Map2, _} = relcast:command(seqmap, RC1_6),
    [{2, 1}, {3, 1}] = lists:sort(maps:to_list(Map2)),
    %% increment the round, the seqmap should increment for 3
    {ok, RC1_7} = relcast:command(next_round, RC1_6),
    {Map3, _} = relcast:command(seqmap, RC1_7),
    [{2, 1}, {3, 2}] = lists:sort(maps:to_list(Map3)),
    %% increment it again, it should increment seqmap for 3 again
    {ok, RC1_8} = relcast:command(next_round, RC1_7),
    {Map4, _} = relcast:command(seqmap, RC1_8),
    [{2, 1}, {3, 3}] = lists:sort(maps:to_list(Map4)),
    relcast:stop(normal, RC1_8),
    ok.

epochs(_Config) ->
    Actors = lists:seq(1, 3),
    {ok, RC1} = relcast:start(1, Actors, test_handler, [1], [{data_dir, "data5"}]),
    {ok, RC1_1a} = relcast:deliver(<<"hello">>, 2, RC1),
    %% try to put an entry in the seq map, it will be deferred because the
    %% relcast is in round 0
    {defer, RC1_2} = relcast:deliver(<<"seq", 1:8/integer>>, 2, RC1_1a),
    {0, _} = relcast:command(round, RC1_2),
    %% go to the next epoch
    {ok, RC1_3} = relcast:command(next_epoch, RC1_2),
    %% queue up another deferred message
    {defer, RC1_4} = relcast:deliver(<<"seq", 2:8/integer>>, 2, RC1_3),
    %% go to the next round
    {ok, RC1_5} = relcast:command(next_round, RC1_4),
    %% check the deferred message from the previous epoch gets handled
    {Map, _} = relcast:command(seqmap, RC1_5),
    [{2, 1}] = maps:to_list(Map),
    %% go to the next round
    {ok, RC1_6} = relcast:command(next_round, RC1_5),
    {2, _} = relcast:command(round, RC1_6),
    %% check the deferred message from the current epoch gets handled
    {Map2, _} = relcast:command(seqmap, RC1_6),
    [{2, 2}] = maps:to_list(Map2),
    %% still outbound data queued from the first epoch
    {ok, Ref, <<"ehlo">>, RC1_7} = relcast:take(2, RC1_6),
    {ok, RC1_8} = relcast:ack(2, Ref, RC1_7),
    {ok, _Ref2, <<"hai">>, RC1_9} = relcast:take(2, RC1_8),
    relcast:stop(normal, RC1_9),
    {ok, CFs} = rocksdb:list_column_families("data5", []),
    ["default", "epoch0000000000", "epoch0000000001"] = CFs,
    %% reopen the relcast and make sure it didn't delete any wrong column
    %% families
    {ok, RC1_10} = relcast:start(1, Actors, test_handler, [1], [{data_dir, "data6"}]),
    relcast:stop(normal, RC1_10),
    {ok, CFs} = rocksdb:list_column_families("data5", []),
    ok.

epochs_gc(_Config) ->
    Actors = lists:seq(1, 3),
    {ok, RC1} = relcast:start(1, Actors, test_handler, [1], [{data_dir, "data6"}]),
    %% try to put an entry in the seq map, it will be deferred because the
    %% relcast is in round 0
    {ok, RC1_1a} = relcast:deliver(<<"hello">>, 2, RC1),
    {defer, RC1_2} = relcast:deliver(<<"seq", 1:8/integer>>, 2, RC1_1a),
    {0, _} = relcast:command(round, RC1_2),
    %% go to the next epoch
    {ok, RC1_3} = relcast:command(next_epoch, RC1_2),
    %% go to the next epoch, this should GC the original epoch
    {ok, RC1_4} = relcast:command(next_epoch, RC1_3),
    %% this is now invalid because we're lacking the previous one
    {ok, RC1_5} = relcast:deliver(<<"seq", 2:8/integer>>, 2, RC1_4),
    %% go to the next round
    {ok, RC1_6} = relcast:command(next_round, RC1_5),
    %% check the deferred message from the previous epoch gets handled
    {Map, _} = relcast:command(seqmap, RC1_6),
    [] = maps:to_list(Map),
    %% go to the next round
    {ok, RC1_7} = relcast:command(next_round, RC1_6),
    {2, _} = relcast:command(round, RC1_7),
    %% check the deferred message from the previous epoch gets handled
    {Map2, _} = relcast:command(seqmap, RC1_7),
    [] = maps:to_list(Map2),
    %% the data from the original epoch has been GC'd
    not_found = relcast:take(2, RC1_7),
    relcast:stop(normal, RC1_7),
    {ok, CFs} = rocksdb:list_column_families("data6", []),
    ["default", "epoch0000000001", "epoch0000000002"] = CFs,
    %% reopen the relcast and make sure it didn't delete any wrong column
    %% families
    {ok, RC1_10} = relcast:start(1, Actors, test_handler, [1], [{data_dir, "data6"}]),
    relcast:stop(normal, RC1_10),
    {ok, CFs} = rocksdb:list_column_families("data6", []),
    %% Re-add the old epoch 0 CF and check it gets removed
    {ok, DB, _} = rocksdb:open_with_cf("data6", [{create_if_missing, true}],
                                       [{"default", []},
                                        {"epoch0000000001", []},
                                        {"epoch0000000002", []}]),
    {ok, _Epoch0} = rocksdb:create_column_family(DB, "epoch0000000000", []),
    rocksdb:close(DB),
    {ok, RC1_11} = relcast:start(1, Actors, test_handler, [1], [{data_dir, "data6"}]),
    relcast:stop(normal, RC1_11),
    {ok, CFs} = rocksdb:list_column_families("data6", []),
    %% delete epoch 1, re-add epoch 0 and check 0 is pruned again because it's non-contiguous
    {ok, DB2, [_, Epoch1, _]} = rocksdb:open_with_cf("data6", [{create_if_missing, true}],
                                       [{"default", []},
                                        {"epoch0000000001", []},
                                        {"epoch0000000002", []}]),
    {ok, _} = rocksdb:create_column_family(DB2, "epoch0000000000", []),
    ok = rocksdb:drop_column_family(Epoch1),
    rocksdb:close(DB2),
    {ok, RC1_12} = relcast:start(1, Actors, test_handler, [1], [{data_dir, "data6"}]),
    relcast:stop(normal, RC1_12),
    {ok, ["default", "epoch0000000002"]} = rocksdb:list_column_families("data6", []),
    ok.

