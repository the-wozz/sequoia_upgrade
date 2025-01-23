#!/bin/bash

# Author: Zachary 'Woz'nicki
# Contributors: Brian Oanes and Andrew Rogers
# What it do: allow upgrades via SUPERMAN from Self Service. adds machine to Static Group which allows for addition of SUPER CP to allow upgrades to next OS version.
# Requirements: + Jamf Pro  +Swift Dialog  +S.U.P.E.R.M.A.N 5
# v2.0 - 12/2/24 - Added support for Sequoia and future versions with new detection style of SUPER Config Profile (without requiring the exact name, now using Key detection)

version="3.0"
versionDate="1/22/25"

# API Variables #
# *** Jamf Pro URL ***
jamfProURL="https://YOURURLHERE.jamfcloud.com"
# Jamf Pro API Client (with correct Permissions!)
apiClientID=""
# Jamf Pro API Client 'Secret'
apiClientSecret=""
# End API Variables #

# Customizable variables #
# Static Group to ADD machine to. *** IMPORTANT *** this should be specified in Parameter 4 of the 'Script' within Jamf Pro
staticGroup=$4
# Target macOS Operating System Numeric Version. *** IMPORTANT *** this should be specified in Parameter 5 of the 'Script' within Jamf Pro
targetOS=$5
# S.U.P.E.R.M.A.N 5 Jamf Pro Policy trigger to install S.U.P.E.R.M.A.N 5
superPolicy="super5"
# Swift Dialog binary FULL location, not advisable to use symlink!
swiftDialog="/usr/local/bin/dialog"
# Swift Dialog icon for notifications, follow Swift Dialog wiki for accepted icons
swiftIcon=""
# macOS Upgrade Icon
SequoiaIcon="SEQUOIA_ICON_LOCATION.png"
# Swift Dialog Jamf Pro policy event trigger for machines that do not have Swift Dialog installed. Swift can be installed prior and this will be ignored
swiftDialogURL="https://github.com/swiftDialog/swiftDialog/releases/download/v2.5.5/dialog-2.5.5-4802.pkg"
# Seconds to look for Profile before exiting, default is 11 minutes, 660
seconds=660
# S.U.P.E.R.M.A.N 5 log file
superLog="/Library/Management/super/logs/super.log"

## DO NOT TOUCH VARIABLES ##
# Serial number of machine
serialNumber=$(system_profiler SPHardwareDataType | /usr/bin/awk '/Serial Number/{print $4}')
# Swift Dialog command file
commandFile="/var/tmp/dialog.log"
# this looks for the SUPER Key: InstallMacOSMajorVersionTarget and reports the Target OS Version in the CP
profileVersionTarget=$(profiles show -o stdout | grep InstallMacOSMajorVersionTarget | awk '{print $3}' | tr -d ';')
# End Variables #

## Functions Start ##

# Obtain Jamf Pro API Access Token
get_Access_Token() {
    /bin/echo "STATUS: Getting Jamf Pro API Access Token..."

    response=$(/usr/bin/curl --retry 5 --retry-max-time 60 -s -L -X POST "$jamfProURL"/api/oauth/token \
                    -H 'Content-Type: application/x-www-form-urlencoded' \
                    --data-urlencode "client_id=$apiClientID" \
                    --data-urlencode 'grant_type=client_credentials' \
                    --data-urlencode "client_secret=$apiClientSecret")
    accessToken=$(/bin/echo "$response" | /usr/bin/plutil -extract access_token raw -)

    if [[ -n "$accessToken" ]]; then
        /bin/echo "STATUS: Jamf Pro API Access Token aquired!"
            #/bin/echo "Access Token: $accessToken" # troubleshooting line
    else
        /bin/echo "ERROR: Unable to get Jamf Pro API Access Token! Unable to do any API calls. Exiting..."
        /bin/echo quit: >> ${commandFile} # quits Swift Dialog window
            exit 1
    fi
}

# Checks if Swift Dialog exists and version, if not-existent (or too old), downloads Swift Dialog
checkSwiftDialog(){
    echo "STATUS: Checking for Swift Dialog..."

    if [[ -e "$swiftDialog" ]]; then
        echo "SWIFT DIALOG! Checking version..."
        sdVer=$(eval "$swiftDialog" -v)
        sdVer2=$(echo "$sdVer" | cut -c 1-5)
        sdURLVer=$(basename "$swiftDialogURL")
        latestSD="${sdURLVer:7:5}"
                # checks if Swift Dialog is older than latest
                if [[ "$sdVer2" < "$latestSD" ]]; then
                    echo "SWIFT DIALOG: Version too old! ($sdVer) | Downloading newer version: ($latestSD)..."
                    downloadSwiftDialog
                else
                    echo "SWIFT DIALOG! Version PASSED! ($sdVer)"
                    return
                fi
    else
        echo "$(timeStamp) SWIFT DIALOG: NOT found! Downloading Swift Dialog $latestSD..."
            downloadSwiftDialog
                return
    fi
}

# downloads Swift Dialog via GitHub
downloadSwiftDialog(){
        echo "* SWIFT DIALOG: Flagged for Download! *"

    if [[ -n "$swiftDialogURL" ]]; then
        echo "SWIFT DIALOG: URL Provided! "

        local filename
            filename=$(basename "$swiftDialogURL")
        local temp_file
            temp_file="/tmp/$filename"
        previous_umask=$(umask)
        umask 077

        /usr/bin/curl -Ls "$swiftDialogURL" -o "$temp_file" 2>&1
            if [[ $? -eq 0 ]]; then
                echo "SWIFT DIALOG: DOWNLOADED successfully! Installing..."
                        /usr/sbin/installer -verboseR -pkg "$temp_file" -target / 2>&1
                            if [[ $? -eq 0 ]]; then
                                echo "SWIFT DIALOG: INSTALLED!"
                            else
                                echo "**** ERROR: SWIFT DIALOG: Unable to instal! Can NOT continue! Exiting... *****"
                                exit 1
                            fi

                rm -Rf "${temp_file}" >/dev/null 2>&1
                umask "${previous_umask}"
            else
                echo "**** ERROR: SWIFT DIALOG: Download FAILED!! Can NOT continue! Exiting... *****"
                exit 1
            fi
    else
        echo "SWIFT DIALOG: ERROR! NO Downlad URL Provided! Exiting..."
        exit 1
    fi
}

# opens the intitial Swift Dialog status/information window
dialogBox(){
    /bin/echo "SWIFT DIALOG: Opening INITIAL information window..."
        "$swiftDialog" -d -o -p --button1text none \
        --width 400 --height 240 --position bottomright --progress \
        -i "$swiftIcon" --iconsize 96 --centericon -y "$SequoiaIcon" \
        --progresstext "Preparing machine for upgrade. Get ready..." \
        -t "macOS $targetOS Upgrade" --titlefont size="17" \
        --messagefont size="10" --messageposition center --messagealignment center -m ""
}

# Need to grab Computer ID (neccessary for certain API calls) from Jamf Pro Inventory record
jamfInventory(){
    # make sure we have a valid access token before grabbing inventory!

    echo "STATUS: Grabbing Jamf Pro Inventory information for $serialNumber..."

    # Jamf API Permission: Read Computers
    inventory=$(/usr/bin/curl -s -L -X GET "$jamfProURL"/JSSResource/computers/serialnumber/"$serialNumber" \
        -H 'accept: application/json' \
        -H "Authorization: Bearer ${accessToken}" )

    # extracts computerID from the inventory json variable
    computerID=$(/bin/echo "$inventory" | grep -o '"id":*[^"]*' | head -n 1 | sed 's/,*$//g' | cut -f2 -d":")
    # alternate command (plutil, possibly preferred way) to get the computer ID
    #computerID=$(/bin/echo "$inventory" | /usr/bin/plutil -extract "computer"."general"."id" raw -)

         echo "Computer ID: $computerID"
            if [[ -z "$computerID" ]]; then
                /bin/echo "*** ERROR: Jamf Computer ID NOT FOUND! Can not continue. Possible internet or VPN issue! Exiting... ****"
                /bin/echo "progresstext: ERROR ❌ Could not locate Jamf Computer ID!<br>Check internet and VPN connection." >> ${commandFile}
                sleep 10 #enough time for user to read message before exiting
                    /bin/echo quit: >> ${commandFile}
                        exit 1
            fi
}

# this checks for Computer Group Memberships on a device
computerMemberships(){
    /bin/echo "Gathering Group Memberships of device..."
    # update user message window
    /bin/echo "progresstext: Checking for Group Memberships..." >> ${commandFile}

        # Jamf API Permissions: Read Computers
        memberships=$(/usr/bin/curl -s -L -X GET "$jamfProURL/api/v1/computers-inventory/$computerID?section=GROUP_MEMBERSHIPS" \
        -H "Authorization: Bearer ${accessToken}" \
        -H 'accept: application/json')

    /bin/echo "STATUS: Checking if $serialNumber is in $staticGroup..."
    # check if the Group Memberships of a machine match the Static Group var ($staticGroup) or if already a part of the group
    if [[ "$memberships" == *"$staticGroup"* ]]; then
        /bin/echo "STATUS: $serialNumber already a part of $staticGroup!"
        /bin/echo "progresstext: Machine already in upgrade group! ✅" >> ${commandFile}
            sleep 5 # allows user to see above message, no other purpose
                # set skip var to skip adding to the static group
                skip=1
                return
    else
        /bin/echo "STATUS: $serialNumber NOT in $staticGroup!"
            # set skip var to not skip adding to the static group
            skip=0
            return
    fi
}

# check if machine is currently in the Static Group
add_To_Static_Group(){

    if [[ "$skip" -eq 0 ]]; then
        /bin/echo "Adding $serialNumber to Jamf Pro 'Computer Static Group': [$staticGroup]"
        /bin/echo "progresstext: ADDING: $serialNumber to $staticGroup" >> ${commandFile}
           # makes sure we have a valid access token before doing an API call 
           get_Access_Token
            # the XML information on adding a computer (the current) to a Static Computer Group
            apiData="<computer_group><computer_additions><computer><serial_number>$serialNumber</serial_number></computer></computer_additions></computer_group>"
            # required for 
            staticGroup_Convert="${staticGroup// /%20}"
                # the actual API call with the attached data
                /usr/bin/curl -s -L -X PUT "$jamfProURL"/JSSResource/computergroups/name/"$staticGroup_Convert" -o /dev/null \
                -H "Authorization: Bearer ${accessToken}" \
                -H "Content-Type: text/xml" \
                --data "${apiData}"

        /bin/sleep 5
        # run a 'Jamf recon' (neccessary to make the machine get the profile(s) more quickly)
        /usr/local/bin/jamf recon
            # wait for recon to finish before proceeding, this also allows time for the SUPER upgrade CP to appear and the Restrictions CP to be removed (for software update deferrals) (tied to the Exclusions)
        /bin/sleep 30

        # need to add: monitor the 'http status code' to determine the result of this success correctly
        /bin/echo "SUCCESS: $serialNumber added to $staticGroup"
        /bin/echo "progresstext: ADDED ✅: $serialNumber to $staticGroup" >> ${commandFile}
            /bin/sleep 3 #allows time for user to see status message of progress
                return
    else
        # processing of machine already in static group
        /bin/echo "STATUS: Skipping add to Static Group: $staticGroup"
        /bin/echo "progresstext: $serialNumber already in $staticGroup.<br>Skipping add, checking for to check" >> ${commandFile}
                return
    fi
}

# checks for the SUPER upgrade profile and waits until it is found or the timer expires
check_For_Profile(){
    /bin/echo "STATUS: Checking for SUPER Upgrade Configuration Profile on machine..."
    /bin/echo "targetOS: $targetOS - profileVersionTarget: $profileVersionTarget" # helpful information for troubleshooting

    # if the machine does not have the SUPER Configuration Profile Target OS Version the same as the 'targetOS' var then we need to wait for it to appear
    #if [[ "$profileVersionTarget" != "$targetOS"  ]]; then
        /bin/echo "progresstext: Checking for macOS Upgrade Configuration Profile to appear on machine..." >> ${commandFile}
        # create a counter
        ProfileWaitCounter=0

        # create a loop to compare the 'targetOS' var to the current SUPER Configuration Profile target OS Version
        while [[ "$profileVersionTarget" != "$targetOS" ]]
            do
                /bin/echo "STATUS: Waiting for SUPER Upgrade Configuration Profile to appear..."
                # updates the profileVersionTarget each time, if you don't, it will only go off the known profileVersionTarget at the beginning of the script...amhIk
                profileVersionTarget=$(profiles show -o stdout | grep InstallMacOSMajorVersionTarget | awk '{print $3}' | tr -d ';')
                    /bin/echo "$profileVersionTarget" >> /dev/null
                # increase our initial counter var by 1 time a second (via sleep)
                ProfileWaitCounter=`expr $ProfileWaitCounter + 1`
                    /bin/sleep 1
                # line to see the counter (good for troubleshooting)
                    #echo "Counter: $ProfileWaitCounter" 
                # this checks for all Profiles on the machine, an alternate way (older) way of going about this process I had once used, still useful if dealing with multiple CPs with the same target OS version
                #profiles=$(/usr/bin/profiles -C -v | /usr/bin/awk -F: '/attribute: name/{print $NF}')

                if [[ "$ProfileWaitCounter" -gt "$seconds" ]]; then
                    /bin/echo "ERROR: Never detected Upgrade profile after $seconds seconds. Exiting..."
                    /bin/echo "progresstext: ERROR: ❌ Could not detect profile. Exiting..." >> ${commandFile}
                        /bin/sleep 10
                        /bin/echo quit: >> ${commandFile}
                            exit 1
                fi
            done
    #fi
        /bin/echo "progresstext: ✅ Upgrade Profile found! Checking for upgrade tool..." >> ${commandFile}
            /bin/sleep 3
                return
}

# Initiates SUPER or calls the Jamf Pro Policy 'superPolicy' to install SUPER if not found. SUPERMAN 5 is REQUIRED for macOS 15 Sequoia
super_Call(){
        /bin/echo "* START-UP: S.U.P.E.R.M.A.N 5 Check *"
        # read the SUPER plist to get the current installed version
        superVersion=$(/usr/bin/defaults read /Library/Management/super/com.macjutsu.super.plist SuperVersion | cut -c1-1)
            /bin/echo "STATUS: Current SUPER Version: $superVersion"
    # SUPER 5 required
    if [[ "$superVersion" -eq 5 ]]; then
        /bin/echo "STATUS: S.U.P.E.R.M.A.N 5 Found! Able to prompt."
        /bin/echo "STATUS: Calling S.U.P.E.R.M.A.N..."
        /Library/Management/super/super --reset-super & sleep 0.1
            return
    # SUPER 5 was not found
    else
        /bin/echo "** CAUTION: S.U.P.E.R.M.A.N 5 NOT found! **"
        /bin/echo "Calling Jamf Pro Policy: $superPolicy"
        /usr/local/jamf/bin/jamf policy -event "$superPolicy" --reset-super & sleep 0.1
            return
    fi
}

# tails SUPER to update the Swift Dialog status window with what is going on until the user is prompted. UPDATED for SUPER 5
superTail() {
        /bin/echo "STATUS: Checking for $superDownloadProgress..."

        # super log file for watching download(s)
        superDownloadProgress=/Library/Management/super/logs/msu-workflow.log
        # create a counter
        superCounter=0
            # added 12/10/24 due to issue of tail not being able to tail because SUPER had not started the download yet... 
            until [[ -e $superDownloadProgress ]]
                do
                    #/bin/echo "STATUS: Waiting for $superDownloadProgress..."
                    sleep 1
                    # increase the counter every second
                    superCounter=`expr $superCounter + 1`

                    # if more than 2 minutes go by until the super.log is found, bail out
                    if [[ "$superCounter" -gt 120 ]]; then
                        /bin/echo "ERROR: Never detected $superDownloadProgress after 2 minutes!"
                        #altTail=1
                        /bin/echo "progresstext: ERROR: ❌ SUPER download progress file not detected.<br>Please run policy again from Self Service." >> ${commandFile}
                            /bin/sleep 15
                                /bin/echo quit: >> ${commandFile}
                                    exit 1
                    fi
                done
        /bin/echo "STATUS: SUPER Log File FOUND! 'Tailing' and continuning..."
        # update Swift Dialog messages for the user
        /bin/echo "progresstext: Starting upgrade download.<br>Please wait..." >> ${commandFile}
        /bin/echo "message: This process generally ranges from 30 minutes to 1 hour." >> ${commandFile}

        /usr/bin/tail -n1 -f "$superDownloadProgress" | while IFS= read -r line
            do
                if [[ "$line" == *"Downloading:"* ]]; then
                    /bin/echo "progresstext: $line" >> ${commandFile}
                    # create a variable for the actual percentage of download and make it the progress bar percent
                    #/bin/echo "progress: $sonomaDownloadPercentVar" >> ${commandFile}
                        /bin/sleep 1
                fi
                if [[ "$line" == *"Downloaded:"* ]] || [[ "$line" == *"COMPLETED"* ]]; then
                    /bin/echo "SUPER: Download complete! Notifying user and exiting..."
                    /bin/echo "progress: 100" >> ${commandFile}
                    /bin/echo "progresstext: ✅ Upgrade downloaded!<br>Preparing upgrade window..." >> ${commandFile}
                        /bin/sleep 25 # allows time for super to pop-up
                            /bin/echo quit: >> ${commandFile}
                                return
                fi
            done
            # if [[ "$altTail" -eq 1 ]]; then
            #         #user has gotten the dialog and 
            #         if [[ "$line" == *"Restart or defer dialog with no timeout"* ]]; then
            #             /bin/echo "progresstext: macOS Sonoma ready for Install ✅ Preparing notification.." >> ${commandFile}
            #             /bin/sleep 25
            #                 /bin/echo quit: >> ${commandFile}
            #                     exit 0
            #         fi
            #         if [[ "$line" == *"User chose to defer update"* ]]; then
            #             /bin/echo quit: >> ${commandFile}
            #                 exit 0
            #         fi
            # fi
    return
}

## End Functions ##

### Main ###
/bin/echo "Version: $version ($versionDate)"

checkSwiftDialog
    dialogBox & sleep 0.2
get_Access_Token
    jamfInventory
computerMemberships
    add_To_Static_Group
check_For_Profile
    super_Call
        superTail
exit 0
