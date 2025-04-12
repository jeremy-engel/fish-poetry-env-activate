# ~/.config/fish/functions/__auto_poetry_env.fish
# Automatically activates/deactivates Poetry virtual environments based on directory.
# Also loads/unloads .env file in project root.

# Helper function to unload .env variables
function __auto_poetry_unload_dotenv
    if set -q __auto_poetry_dotenv_loaded_vars
        for var_name in $__auto_poetry_dotenv_loaded_vars
            set -e $var_name # Erase the variable
        end
        set -e __auto_poetry_dotenv_loaded_vars # Clean up the tracking list
    end
end

# Helper function to load .env variables
function __auto_poetry_load_dotenv -a project_root
    set -l dotenv_path "$project_root/.env"
    if test -f "$dotenv_path"
        # Ensure the cleanup list exists and is global, clear it initially for this load
        set -q __auto_poetry_dotenv_loaded_vars; or set -g __auto_poetry_dotenv_loaded_vars ""
        set -e __auto_poetry_dotenv_loaded_vars[1] # Clear the list if it existed

        while read -l line
            # Skip comments and empty lines
            if string match -q -r '^\s*#|^\s*$' -- "$line"
                continue
            end

            # Use string split for parsing
            set -l parts (string split -m 1 '=' -- "$line")
            if test (count $parts) -eq 2
                set -l var_name (string trim -- $parts[1])
                # Trim whitespace and potential quotes (' or ") from value
                set -l var_value (string trim -- (string trim -c '"\'' -- $parts[2]))

                # Validate the variable name before setting
                if test -n "$var_name"; and string match -q -r '^[a-zA-Z_][a-zA-Z0-9_]*$' -- "$var_name"
                    set -gx $var_name $var_value # Set as global exported variable
                    # Add to list for cleanup if set succeeded, avoid duplicates
                    if test $status -eq 0; and not contains -- $var_name $__auto_poetry_dotenv_loaded_vars
                        set -a __auto_poetry_dotenv_loaded_vars $var_name
                    end
                end
            end
        end < "$dotenv_path"
        return 0 # Success
    end
    return 1 # .env not found or not readable
end

function __auto_poetry_env --on-event fish_prompt
    # Exit if poetry command isn't found
    if not command -v poetry > /dev/null
        return 0
    end

    # Find project root (directory containing pyproject.toml)
    set -l current_dir (pwd)
    set -l project_root ""
    set -l temp_dir $current_dir
    while test "$temp_dir" != "/"
        if test -f "$temp_dir/pyproject.toml"
            set project_root $temp_dir
            break
        end
        set temp_dir (dirname $temp_dir)
    end
    # Check root directory itself
    if test -f "/pyproject.toml"; and test -z "$project_root"
        set project_root /
    end

    # Get currently active virtual environment path
    set -l current_venv $VIRTUAL_ENV

    # --- Activation Logic ---
    if test -n "$project_root" # We are inside a Poetry project tree
        # Get the expected venv path for this specific project
        # Run in a subshell within the project dir to avoid errors/polluting status
        set -l expected_venv_path (cd "$project_root"; poetry env info --path 2>/dev/null) # Redirect stderr again
        set -l poetry_status $status

        # Check if poetry found an environment for this project
        if test $poetry_status -eq 0; and test -n "$expected_venv_path"
            set -l activate_script "$expected_venv_path/bin/activate.fish"

            # Check if the activation script exists
            if test -f "$activate_script"
                # Activate if no env is active, or if the wrong one is active
                if test -z "$current_venv"; or test "$current_venv" != "$expected_venv_path"
                    # Deactivate previous env first if it exists and was tracked
                    if test -n "$current_venv"; and set -q __auto_poetry_activated_root; and test -n "$__auto_poetry_activated_root"
                        # Unload previous .env vars *before* deactivating
                        __auto_poetry_unload_dotenv
                        if functions -q deactivate
                            deactivate
                        end
                        # Ensure tracking var is clear *after* potential deactivate call
                        set -e __auto_poetry_activated_root
                    end
                    # Source the activation script
                    source "$activate_script"
                    # If activation succeeded, track the project root
                    if test $status -eq 0
                        set -g __auto_poetry_activated_root "$project_root"
                        # Load .env variables
                        __auto_poetry_load_dotenv "$project_root"
                    else
                        # Activation failed, ensure no tracking or .env vars linger
                        __auto_poetry_unload_dotenv # Attempt cleanup just in case
                        if set -q __auto_poetry_activated_root; and test "$__auto_poetry_activated_root" = "$project_root"
                            set -e __auto_poetry_activated_root
                        end
                    end
                else
                    # Correct environment is already active, ensure we are tracking it
                    # And ensure .env vars are loaded if they weren't (e.g., manual activation)
                    if not set -q __auto_poetry_dotenv_loaded_vars
                        __auto_poetry_load_dotenv "$project_root"
                    end
                    # Always ensure tracking var is set if correct env is active
                    set -g __auto_poetry_activated_root "$project_root"
                end
            else
                # Activation script missing. If we were tracking this env, deactivate and clean up.
                if set -q __auto_poetry_activated_root; and test "$__auto_poetry_activated_root" = "$project_root"
                    if set -q __auto_poetry_activated_root; and test "$__auto_poetry_activated_root" = "$project_root"
                        set -e __auto_poetry_activated_root
                    end
                end
            end
        else
            # 'poetry env info' failed for this project. Deactivate if we were tracking it.
            if set -q __auto_poetry_activated_root; and test "$__auto_poetry_activated_root" = "$project_root"
                __auto_poetry_unload_dotenv
                if test -n "$current_venv"; and functions -q deactivate
                    deactivate
                end
                set -e __auto_poetry_activated_root
            end
        end

    # --- Deactivation Logic ---
    else # We are outside a Poetry project tree
        # Deactivate if an env is active AND it was one activated/tracked by this script
        if test -n "$current_venv"; and set -q __auto_poetry_activated_root; and test -n "$__auto_poetry_activated_root"
            # Unload .env vars *before* deactivating
            __auto_poetry_unload_dotenv
            # Check if the deactivate function exists
            if functions -q deactivate
                deactivate
            end
            # Clear the tracking variable since we've left the project
            set -e __auto_poetry_activated_root
        end
    end

    return 0
end

# Optional: Ensure fish saves the function definition if edited interactively
# funcsave __auto_poetry_unload_dotenv
# funcsave __auto_poetry_load_dotenv
# funcsave __auto_poetry_env
