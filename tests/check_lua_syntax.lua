for i = 1, #arg do
    local chunk, err = loadfile(arg[i])
    if not chunk then
        io.stderr:write(err, "\n")
        os.exit(1)
    end
end
