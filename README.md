Hailfire Era
==============

Description
--------------
"Hailfire Era" is a multiplayer add-on campaign for the game Battle for Wesnoth. It mainly adds an extra game mechanic "climate" in addition to alignment and terrain, for most units in the Default Era plus three new multiplayer factions inlcuding two heavily modified versions of older factions. The ultimate goal is featuring a new game mechanic that other add-on authors can rewrite and employ as desired. 

Other information
--------------
The author of this campaign is time_area but the format for this readme was made by Dugi, creator of Legend of the Invincibles (spelled as Dugy on GitHub). The address of time_area's git repository (github page for Hailfire Era) is https://github.com/Orwell64124/Hailfire_Era. The forum thread discussing Hailfire Era is at . This is the best place to discuss anything related to the Hailfire Era.

Usage
--------------
The add-on is usually downloaded from the game's add-on server. If you wish to use the version from GitHub, look at https://wiki.wesnoth.org/EditingWesnoth to see how to use it.

Code style
--------------
Lua code uses snake case and tab indentation. The breaking of long lines is not decided on.

WML code uses the generally recommended code style, snake case for variable names, four spaces for indentation.

Its usage of space indentation bears no advantage over tabs, but increases file size and is inconsistent with automatically generated and indented code by the game engine (that uses tabs). If you want to use tabs instead, you can have git filter the code for you, on your local repository only:

* create a file `git/info/attributes` containing `*.cfg filter=tabspace`
* use command `git config filter.tabspace.smudge 'unexpand --tabs=4 --first-only'`
* use command `git config -filter.tabspace.clean 'expand --tabs=4 --initial'`
* delete all files of type `.cfg` in the repository and use `git reset --hard`
* edit the editorconfig file and untrack it `git update-index --assume-unchanged .editorconfig`
