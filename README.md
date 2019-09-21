dotconsole
==========

This program provides an interactive editor for Graphviz.

Obsolescence Warning
--------------------

This program is no longer maintained.
I suggest using the
[Graphviz Preview](https://marketplace.visualstudio.com/items?itemName=EFanZh.graphviz-preview)
extension to [Visual Studio Code](https://code.visualstudio.com/)
instead.

This program depends on Gtk2.
It could perhaps be updated to Gtk3 but there is no working gtk3-perl
in Debian.

Dependencies
------------

    apt-get install libgtk2-perl graphviz

Installation
------------

To install, run the following commands:

    perl Makefile.PL
    make
    make install

Documentation
-------------

After installing, you can find documentation with the perldoc command.

    perldoc dotconsole

License And Copyright
---------------------

Copyright © 2013 Richard Kettlewell

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
