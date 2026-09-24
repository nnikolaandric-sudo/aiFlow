-- aiFlowSave.applescript
--
-- Mail.app Rule (Run AppleScript): svaki dolazni mail snima kao .eml
-- u jedini Email folder (Email/Inbox). aiFlow Sync ga odatle pokupi,
-- klasifikuje, fajluje i arhivira izvor u Done. Radi sa SVIM nalozima u
-- Mail.app-u (Gmail, Outlook, iCloud, IMAP) — bez OAuth klijenata i lozinki.
--
-- Instalacija:
--   1. osacompile -o ~/Library/Application\ Scripts/com.apple.mail/aiFlowSave.scpt tools/mail-rule/aiFlowSave.applescript
--   2. Restartuj Mail (listu skripti cita samo pri startu).
--   3. Mail → Settings → Rules → Add Rule:
--        uslov (npr. Subject contains Valens — za pocetak usko!)
--        akcija: Run AppleScript → aiFlowSave
--   4. Postojecu poruku: selektuj je → Message → Apply Rules.
--   5. Dijagnoza: cat ~/Documents/FinderFlow/Email/mailrule.log
--
-- Napomene:
--   - Ime fajla je md5 Message-ID-a; pravi dedup ionako radi Message-ID
--     header u store-u, pa su ponovni runovi bezbedni.
--   - Ako si premestio Email folder (ffMailRoot), izmeni INBOX rucno.

using terms from application "Mail"
	on perform mail action with messages theMessages for rule theRule
		set logPath to "~/Documents/FinderFlow/Email/mailrule.log"
		do shell script "mkdir -p ~/Documents/FinderFlow/Email/Inbox/; echo \"$(date '+%F %T') rule fired, count=" & (count of theMessages) & "\" >> " & logPath
		set inboxPath to (POSIX path of (path to documents folder)) & "FinderFlow/Email/Inbox/"
		repeat with theMessage in theMessages
			set filePath to ""
			try
				set rawSource to source of theMessage
				set msgID to message id of theMessage
				do shell script "echo \"$(date '+%F %T') got-source len=" & (length of rawSource) & " id=" & quoted form of msgID & "\" >> " & logPath
				set hashName to do shell script "md5 -q -s " & quoted form of msgID
				set filePath to inboxPath & hashName & ".eml"
				set f to open for access POSIX file filePath with write permission
				set eof of f to 0
				write rawSource to f
				close access f
				do shell script "echo \"$(date '+%F %T') wrote " & quoted form of filePath & "\" >> " & logPath
			on error errMsg number errNum
				do shell script "echo \"$(date '+%F %T') ERROR " & errNum & " " & quoted form of errMsg & "\" >> " & logPath
				try
					if filePath is not "" then close access POSIX file filePath
				end try
			end try
		end repeat
	end perform mail action with messages
end using terms from
