#!/bin/bash

# Dependencies: git java adb calabash genymotion

# Settings
REPO=git@github.com:maxcruz/todo_app.git
BRANCH=master
PACKAGE=com.example.todoapp

SAMPLES=1
MONKEY_EVENTS=100

MDROID_REPO=https://gitlab.com/miso-4208-labs/MDroidPlus
MDROID_PATH=MDroidPlus
MDROID_RUN=$MDROID_PATH/target/MDroidPlus-1.0.0.jar

GENYMOTION_RUN=/opt/genymotion/player
GENYMOTION_EMULATOR_ID=0e7a522d-598a-4ea6-acbb-b176037ac7f5

# Get the app directory from repo url
APP_PATH=$(echo $REPO | awk -F/ '{print $2}' | rev | cut -c 5- | rev)

# Verify if the repo is already in the work directory
if [ -d "$APP_PATH" ]; then
  # Update the branch with the last changes
  cd $APP_PATH
  git reset --hard
  git pull origin $BRANCH
  cd ..
else 
  # Clone the repo from the URL
  git clone $REPO
  if [ ! -d "$APP_PATH" ]; then
    # Control will enter here if the app doesn't exist.
    echo "The app can't be retrieved"
    exit 1
  else 
    # Checkout the working branch
    cd $APP_PATH
    git checkout $BRANCH
    cd ..
  fi
fi 

# Verify if MDROID+ is ready
if [ ! -d "$MDROID_PATH" ]; then
  git clone $MDROID_REPO
fi

# Verify that MDROID+ is built
if [ ! -f "$MDROID_RUN" ]; then
  cd MDroidPlus
  mvn clean
  mvn package
  cd ..
fi

#Create directory for the mutants
mkdir mutants

# Generate mutants
java -jar $MDROID_RUN libs4ast ./$APP_PATH/app/src/main $PACKAGE mutants

# Launch emulator
$GENYMOTION_RUN --args --vm-name "$GENYMOTION_EMULATOR_ID" &
#sleep 20

# Select samples mutants randomly
N_MUTANTS=$(expr $(ls -1 mutants  | wc -l) - 1)
SELECTED=$(shuf -i1-$N_MUTANTS -n$SAMPLES | awk 'BEGIN { ORS = " " } { print }' )

# Log file name base for this execution
DATE=$(date '+%y%m%d%H%M')
LOG_FILE="run-$DATE"

# Use the same seed for monkeys
SEED=$(shuf -i 1-99999 -n1)

# Iterate the selected mutants
for I in $SELECTED; do

  # Set the sources with the mutation
  MUTANT_DIR="mutants/$PACKAGE-mutant$I"
  MUTANTS_LOG="mutants/$PACKAGE-mutants.log"

  # Verify source directory
  if [ -d "$MUTANT_DIR" ]; then

    # Generate log for this mutation
    TITLE="Mutant $I source: $MUTANT_DIR"
    echo $TITLE
    echo -e "\n$TITLE" >> "$LOG_FILE.tmp"

    # Identify the mutation inserted
    MUTATION=$(cat $MUTANTS_LOG | grep "$MUTANT_DIR/" | awk -F" " '{ print $4 }')
    echo "Mutation: $MUTATION" >> "$LOG_FILE.tmp"

    # Replace sources
    cp -rf $MUTANT_DIR/* $APP_PATH/app/src/main
    cd $APP_PATH

    # Run unit tests and save logs
    ./gradlew test | tail -n2 >> "../$LOG_FILE.tmp"

    # Build apk
    ./gradlew assembleDebug
    APK=app/build/outputs/apk/debug/app-debug.apk
    FILTER="events injected:\|crash"
    if [ -f "$APK" ]; then

	# Clear data from previous installations
        adb uninstall $PACKAGE
        
        # Install the new APK
        adb install -f $APK
       
        # Run monkey and save relevant logs
	echo "Inject $MONKEY_EVENTS pseudo-random events with seed $SEED " >> "../$LOG_FILE.tmp"
        adb shell monkey -p $PACKAGE --pct-touch 75 --pct-anyevent 25 -v -s $SEED $MONKEY_EVENTS > "../out$I.tmp"
        cat "../out$I.tmp" | grep -i "$FILTER" >> "../$LOG_FILE.tmp"
	rm "../out$I.tmp"
        
        # Run calabash and save logs
        if [ -d "calabash" ]; then
          
          # Sign apk and run tests
          calabash-android resign $APK
          cd calabash
          bundle exec calabash-android run ../$APK | tail -n3 >> "../../$LOG_FILE.tmp"
          cd ..

        fi 


    else 
      echo "Stillborn mutant" >> "../$LOG_FILE.tmp"
    fi    

    cd ..
    
  fi
done

# Uppercase format
cat "$LOG_FILE.tmp" | tr '[:lower:]' '[:upper:]' > "$LOG_FILE.log"
rm "$LOG_FILE.tmp"

# Close emulator
killall player

# Clean working directory
rm -rf mutants

