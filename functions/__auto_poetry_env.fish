# ~/.config/fish/functions/__auto_poetry_env.fish
# Automatically activates/deactivates Poetry virtual environments based on directory.
# Also loads/unloads .env file in project root.

# Helper function to unload .env variables (keep as is)
function __auto_poetry_unload_dotenv
    if set -q __auto_poetry_dotenv_loaded_vars
        for var_name in $__auto_poetry_dotenv_loaded_vars
            set -e $var_name # Erase the variable
        end
        set -e __auto_poetry_dotenv_loaded_vars # Clean up the tracking list
    end
end

# Helper function to load .env variables (keep as is)
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
        end <"$dotenv_path"
        return 0 # Success
    end
    return 1 # .env not found or not readable
end

# --- Main Prompt Hook Function ---
function __auto_poetry_env --on-event fish_prompt
    # Initialize tracking list for failed roots if it doesn't exist
    set -q __auto_poetry_failed_roots; or set -g __auto_poetry_failed_roots

    # Exit if poetry command isn't found
    if not command -v poetry >/dev/null
        # Clear tracking vars if poetry disappears
        if set -q __auto_poetry_activated_root
            __auto_poetry_unload_dotenv
            set -e __auto_poetry_activated_root
        end
        # We don't clear __auto_poetry_failed_roots here, maybe poetry will come back
        return 0
    end

    # Find project root (directory containing pyproject.toml)
    set -l current_dir (pwd)
    set -l project_root ""
    set -l temp_dir $current_dir
    while test "$temp_dir" != /
        if test -f "$temp_dir/pyproject.toml"
            set project_root $temp_dir
            break
        end
        set temp_dir (dirname $temp_dir)
    end
    if test -f "/pyproject.toml"; and test -z "$project_root"
        set project_root /
    end
    # echo "DEBUG: Found project_root: '$project_root'" # Optional

    # Get currently active virtual environment path and tracked root
    set -l current_venv $VIRTUAL_ENV
    set -l activated_root ""
    if set -q __auto_poetry_activated_root
        set activated_root $__auto_poetry_activated_root
    end
    # echo "DEBUG: current_venv: '$current_venv', activated_root: '$activated_root'" # Optional
    # echo "DEBUG: Failed roots list: '$__auto_poetry_failed_roots'" # Optional

    # --- OPTIMIZATION 1: Skip known failed roots ---
    if test -n "$project_root"; and contains -- "$project_root" $__auto_poetry_failed_roots
        # echo "DEBUG: Optimization hit - Known failed root ($project_root), skipping." # Optional
        # If an unrelated venv is somehow active, we don't touch it.
        # If the activated_root matches this failed root (shouldn't happen often), deactivate it.
        if test "$project_root" = "$activated_root"
            __auto_poetry_unload_dotenv
            if functions -q deactivate
                deactivate
            end
            set -e __auto_poetry_activated_root
            set activated_root "" # Update local state
        end
        return 0
    end

    # --- OPTIMIZATION 2: Skip if state hasn't changed (same active project) ---
    if test -n "$project_root"; and test -n "$activated_root"; and test "$project_root" = "$activated_root"
        # echo "DEBUG: Optimization hit - Same active project root ($project_root), skipping." # Optional
        if not set -q __auto_poetry_dotenv_loaded_vars
            __auto_poetry_load_dotenv "$project_root"
        end
        return 0
    end

    # --- OPTIMIZATION 3: Skip if outside project and no tracked venv active ---
    if test -z "$project_root"; and test -z "$activated_root"
        # echo "DEBUG: Optimization hit - Outside project and no tracked venv active, skipping." # Optional
        return 0
    end
    # echo "DEBUG: Optimization checks passed, proceeding..." # Optional

    # --- State has changed, proceed with activation/deactivation logic ---
    set -l previous_activated_root $activated_root # Store for potential cleanup

    # --- Deactivation Logic ---
    # If a tracked venv was active, but we are now outside a project OR in a *different* project
    if test -n "$activated_root"; and begin
            test -z "$project_root"; or test "$project_root" != "$activated_root"
        end
        # echo "DEBUG: Deactivation condition met. Deactivating env from $activated_root" # Optional
        __auto_poetry_unload_dotenv
        if functions -q deactivate
            # echo "DEBUG: Calling deactivate function" # Optional
            deactivate
            # echo "DEBUG: Deactivate function finished. Status: $status" # Optional
        end
        # Clear the tracking variable *after* deactivation attempt
        set -e __auto_poetry_activated_root
        # Update state for subsequent logic
        set activated_root ""
        set current_venv $VIRTUAL_ENV # Re-check VIRTUAL_ENV after deactivate

        # Since this root *was* active, ensure it's not in the failed list
        set -l idx (contains -i -- "$previous_activated_root" $__auto_poetry_failed_roots)
        if test $status -eq 0
            # echo "DEBUG: Removing previously active root $previous_activated_root from failed list" # Optional
            set -e __auto_poetry_failed_roots[$idx]
        end
    end

    # --- Activation Logic ---
    # If we are inside a project AND it's not the currently activated one (or none is active)
    # AND it's not known to be a failed root (already checked by optimization 1)
    if test -n "$project_root"; and test "$project_root" != "$activated_root"
        # echo "DEBUG: Activation condition met. Attempting activation for $project_root" # Optional
        # Get the expected venv path for this specific project
        # echo "DEBUG: Running 'poetry env info --path' in $project_root" # Optional
        set -l expected_venv_path (cd "$project_root"; poetry env info --path 2>/dev/null)
        set -l poetry_status $status
        # echo "DEBUG: 'poetry env info --path' status: $poetry_status, path: '$expected_venv_path'" # Optional

        if test $poetry_status -eq 0; and test -n "$expected_venv_path"
            # Success finding environment path
            set -l activate_script "$expected_venv_path/bin/activate.fish"
            # echo "DEBUG: Found activate script: '$activate_script'" # Optional

            if test -f "$activate_script"
                # Deactivate any *other* potentially active venv first
                if test -n "$current_venv"; and test "$current_venv" != "$expected_venv_path"
                    if functions -q deactivate
                        # echo "DEBUG: Calling deactivate (pre-activation)" # Optional
                        deactivate
                        # echo "DEBUG: Deactivate (pre-activation) finished. Status: $status" # Optional
                    end
                end

                # Source the activation script
                # echo "DEBUG: Sourcing $activate_script" # Optional
                source "$activate_script"
                # echo "DEBUG: Sourcing finished. Status: $status" # Optional

                if test $status -eq 0
                    # Activation succeeded
                    set -g __auto_poetry_activated_root "$project_root"
                    __auto_poetry_load_dotenv "$project_root"
                    # Ensure this root is removed from the failed list now that it works
                    set -l idx (contains -i -- "$project_root" $__auto_poetry_failed_roots)
                    if test $status -eq 0
                        # echo "DEBUG: Removing newly activated root $project_root from failed list" # Optional
                        set -e __auto_poetry_failed_roots[$idx]
                    end
                else
                    # Activation failed (source command failed)
                    __auto_poetry_unload_dotenv # Attempt cleanup
                    if set -q __auto_poetry_activated_root; and test "$__auto_poetry_activated_root" = "$project_root"
                        set -e __auto_poetry_activated_root
                    end
                    # Should we add to failed list here? Maybe not, sourcing error != lookup error.
                end
            else
                # Activation script missing - Treat as failure for this project root
                # echo "DEBUG: Activation script not found: $activate_script" # Optional
                if not contains -- "$project_root" $__auto_poetry_failed_roots
                    # echo "DEBUG: Adding $project_root to failed list (script missing)" # Optional
                    set -a __auto_poetry_failed_roots "$project_root"
                end
                if set -q __auto_poetry_activated_root; and test "$__auto_poetry_activated_root" = "$project_root"
                    set -e __auto_poetry_activated_root
                end
            end
        else
            # 'poetry env info --path' failed or returned empty - Treat as failure
            # echo "DEBUG: poetry env info failed or no path for $project_root" # Optional
            if not contains -- "$project_root" $__auto_poetry_failed_roots
                # echo "DEBUG: Adding $project_root to failed list (lookup failed)" # Optional
                set -a __auto_poetry_failed_roots "$project_root"
            end
            # Ensure we don't track this root as active if lookup failed
            if set -q __auto_poetry_activated_root; and test "$__auto_poetry_activated_root" = "$project_root"
                set -e __auto_poetry_activated_root
            end
        end
    end

    # echo "DEBUG: __auto_poetry_env finished." # Optional
    return 0
end

# Optional: Ensure fish saves the function definition if edited interactively
# funcsave __auto_poetry_unload_dotenv
# funcsave __auto_poetry_load_dotenv
# funcsave __auto_poetry_env
