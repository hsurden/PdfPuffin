set out to ""
tell application "System Events"
  tell process "PDF Expert"
    repeat with mName in {"File","Edit","View","Annotate","Go","Window"}
      set m to menu 1 of menu bar item mName of menu bar 1
      repeat with mi in menu items of m
        try
          set t to name of mi
          if t is not missing value then
            set c to ""
            set md to ""
            try
              set c to value of attribute "AXMenuItemCmdChar" of mi
            end try
            try
              set md to value of attribute "AXMenuItemCmdModifiers" of mi
            end try
            try
              set vk to value of attribute "AXMenuItemCmdVirtualKey" of mi
            on error
              set vk to ""
            end try
            set out to out & mName & " | " & t & " | " & c & " | " & md & " | " & vk & linefeed
            try
              repeat with sub in menu items of menu 1 of mi
                set stt to name of sub
                set sc to ""
                set smd to ""
                try
                  set sc to value of attribute "AXMenuItemCmdChar" of sub
                end try
                try
                  set smd to value of attribute "AXMenuItemCmdModifiers" of sub
                end try
                if stt is not missing value then set out to out & "   " & t & " > " & stt & " | " & sc & " | " & smd & linefeed
              end repeat
            end try
          end if
        end try
      end repeat
    end repeat
  end tell
end tell
return out
