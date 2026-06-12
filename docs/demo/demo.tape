# fixbuddy demo — recorded with VHS (https://github.com/charmbracelet/vhs).
# Run via: bash docs/demo/gen.sh   (sets up PATH/env, then runs `vhs` on this file)
Output docs/demo.gif

Require fixbuddy

Set Shell "bash"
Set FontSize 16
Set Width 1320
Set Height 600
Set Padding 24
Set Theme "Dracula"
Set TypingSpeed 35ms

Sleep 600ms
Type "fixbuddy --repo acme/calc --project /tmp/fixbuddy-demo/playground --yes"
Sleep 500ms
Enter
Sleep 9s
