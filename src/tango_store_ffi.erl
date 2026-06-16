-module(tango_store_ffi).
-include_lib("kernel/include/file.hrl").
-export([
    argv/0,
    get_env/1,
    find_executable/1,
    ensure_dir/1,
    now_rfc3339/0,
    unique_id/1,
    run_command/4,
    stable_hash/1,
    sha256/1,
    confirm/1,
    atomic_replace/2,
    atomic_create/2,
    read/1,
    is_regular_file_no_symlink/1,
    modified_at_seconds/1,
    list_dir/1,
    temporary_directory/1,
    remove_tree/1
]).

argv() ->
    [unicode:characters_to_binary(Arg) || Arg <- init:get_plain_arguments()].

get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> none;
        Value -> {some, unicode:characters_to_binary(Value)}
    end.

find_executable(Name) ->
    case os:find_executable(binary_to_list(Name)) of
        false -> none;
        Path -> {some, unicode:characters_to_binary(Path)}
    end.

ensure_dir(Path) ->
    Dir = unicode:characters_to_list(Path),
    case filelib:ensure_dir(filename:join(Dir, ".keep")) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

now_rfc3339() ->
    {{Year, Month, Day}, {Hour, Minute, Second}} =
        calendar:system_time_to_universal_time(erlang:system_time(second), second),
    iolist_to_binary(
        io_lib:format(
            "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ",
            [Year, Month, Day, Hour, Minute, Second]
        )
    ).

unique_id(Prefix) ->
    iolist_to_binary([
        Prefix,
        "-",
        integer_to_binary(erlang:system_time(nanosecond)),
        "-",
        integer_to_binary(erlang:unique_integer([positive, monotonic]))
    ]).

stable_hash(Value) ->
    integer_to_binary(erlang:phash2(Value)).

sha256(Value) ->
    binary:encode_hex(crypto:hash(sha256, Value), lowercase).

confirm(Prompt) ->
    ok = io:put_chars(unicode, Prompt),
    case io:get_line("") of
        eof -> false;
        Line ->
            case string:lowercase(string:trim(unicode:characters_to_binary(Line), both)) of
                <<"y">> -> true;
                <<"yes">> -> true;
                _ -> false
            end
    end.

run_command(Command, Args, Env, Cwd) ->
    case resolve_executable(Command) of
        {ok, Executable} ->
            PortSettings0 = [
                binary,
                exit_status,
                hide,
                use_stdio,
                stderr_to_stdout,
                {args, [unicode:characters_to_list(Arg) || Arg <- Args]},
                {env, [{unicode:characters_to_list(Key), unicode:characters_to_list(Val)} || {Key, Val} <- Env]}
            ],
            PortSettings = case Cwd of
                none -> PortSettings0;
                {some, Dir} -> [{cd, unicode:characters_to_list(Dir)} | PortSettings0]
            end,
            try
                Port = open_port({spawn_executable, Executable}, PortSettings),
                collect_port(Port, [])
            catch
                error:enoent -> {error, executable_not_found(Command)};
                error:Reason -> {error, command_error(Command, Reason)}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

resolve_executable(Command) ->
    CommandList = unicode:characters_to_list(Command),
    case lists:member($/, CommandList) of
        true ->
            {ok, CommandList};
        false ->
            case os:find_executable(CommandList) of
                false -> {error, executable_not_found(Command)};
                Path -> {ok, Path}
            end
    end.

executable_not_found(Command) ->
    iolist_to_binary([<<"executable not found: ">>, Command]).

command_error(Command, Reason) ->
    iolist_to_binary(
        io_lib:format(
            "failed to run ~ts: ~p",
            [unicode:characters_to_list(Command), Reason]
        )
    ).

atomic_replace(Path, Contents) ->
    case ensure_parent(Path) of
        ok ->
            Temp = <<Path/binary, ".tmp">>,
            case write_synced(Temp, Contents, [write, binary]) of
                ok ->
                    case file:rename(Temp, Path) of
                        ok -> {ok, nil};
                        {error, Reason} ->
                            _ = file:delete(Temp),
                            {error, atom_to_binary(Reason)}
                    end;
                {error, Reason} -> {error, atom_to_binary(Reason)}
            end;
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

atomic_create(Path, Contents) ->
    case ensure_parent(Path) of
        ok ->
            case write_synced(Path, Contents, [write, exclusive, binary]) of
                ok -> {ok, nil};
                {error, Reason} -> {error, atom_to_binary(Reason)}
            end;
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

read(Path) ->
    case file:read_file(Path) of
        {ok, Contents} -> {ok, Contents};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

is_regular_file_no_symlink(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = regular}} -> true;
        _ -> false
    end.

modified_at_seconds(Path) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, Info} -> {ok, Info#file_info.mtime};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

list_dir(Path) ->
    case file:list_dir(Path) of
        {ok, Entries} ->
            {ok, lists:sort([unicode:characters_to_binary(Entry) || Entry <- Entries])};
        {error, enoent} -> {ok, []};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

temporary_directory(Prefix) ->
    Base = case os:getenv("TMPDIR") of
        false -> <<"/tmp">>;
        Value -> unicode:characters_to_binary(Value)
    end,
    Name = iolist_to_binary([
        Prefix,
        "-",
        integer_to_binary(erlang:system_time(nanosecond)),
        "-",
        integer_to_binary(erlang:unique_integer([positive, monotonic]))
    ]),
    Path = filename:join(Base, Name),
    case file:make_dir(Path) of
        ok -> {ok, Path};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

remove_tree(Path) ->
    case file:del_dir_r(Path) of
        ok -> {ok, nil};
        {error, enoent} -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

ensure_parent(Path) ->
    filelib:ensure_dir(Path).

write_synced(Path, Contents, Options) ->
    case file:open(Path, Options) of
        {ok, IoDevice} ->
            Result =
                case file:write(IoDevice, Contents) of
                    ok -> file:sync(IoDevice);
                    Error -> Error
                end,
            _ = file:close(IoDevice),
            Result;
        Error -> Error
    end.

collect_port(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_port(Port, [Acc, Data]);
        {Port, {exit_status, Status}} ->
            {ok, {command_result, Status, iolist_to_binary(Acc)}}
    end.
