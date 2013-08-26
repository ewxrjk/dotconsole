# © 2013 Richard Kettlewell
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see
# <http://www.gnu.org/licenses/>.

package Greenend::DotConsole::Window;
use warnings;
use strict;
use utf8;
use Gtk2;
use Gtk2::SourceView2;
use Gtk2::Gdk::Keysyms;
use Glib;
use File::Basename;
use POSIX;
use Time::HiRes;

our $VERSION = "0.1";

my $serial = 0;                         # serial number for windows, tmpdirs
my %windows = ();                       # $windows{SERIAL} tracks open windows

# Fonts
my $editorFontName = "monospace 10";
my $editorFont = Pango::FontDescription->from_string($editorFontName);

# Constructor
sub new {
    my $self = bless {}, shift;
    return $self->initialize(@_);
}

# Initialize a new window
sub initialize($) {
    my $self = shift;

    # Keep track of open windows
    $self->{serial} = $serial++;
    $windows{$self->{serial}} = $self;

    # Window widget
    $self->{window} = new Gtk2::Window('toplevel');
    $self->{window}->set_title("dotconsole");
    $self->{window}->set_size_request(960, 640);
    $self->{window}->signal_connect('delete-event' =>
                                    sub {
                                        $self->cmdClose();
                                        return 1;
                                    });
    # Terminate when last window is destroyed
    $self->{window}->signal_connect('destroy' =>
                                    sub {
                                        delete $windows{$self->{serial}};
                                        Glib::Source->remove($self->{timerId});
                                        Gtk2->main_quit() if !keys %windows;
                                    });

    # Accelerators
    $self->{accelerators} = Gtk2::AccelGroup->new();
    $self->{window}->add_accel_group($self->{accelerators});

    # Create widgets
    $self->createMenuBar();
    $self->createGraphPane();
    $self->createErrorPane();
    $self->createEditingPane();

    # Display them
    $self->layout();

    # Detect size changes
    $self->{graphScroll}->signal_connect('size-allocate' =>
                                          sub {
                                              $self->graphSizeChanged(@_);
                                          });

    $self->setScale('fit');             # Default scaling
    $self->{editorView}->grab_focus();  # Input focus on editor window
    $self->setSensitive();              # Set widget sensitivies
    $self->{window}->show_all();        # Make everything visible

    # Regularly check for subprocesses completion and text changes
    $self->{timerId} = Glib::Timeout->add(100,
                                          sub {
                                              $self->checkRenderComplete();
                                              $self->checkTextChanged();
                                              return 1;
                                          });

    return $self;
}

# Layout ----------------------------------------------------------------------

# Lay out the window
sub layout($) {
    my $self = shift;

    # Graph and errors are separate tabs in a notebook; the
    # most appropriate will be selected after re-rendering.
    $self->{notebook} = new Gtk2::Notebook();
    $self->{graphScroll} = $self->scroll($self->{graphImage});
    $self->{notebook}->append_page($self->{graphScroll}, "Graph");
    $self->{errorScroll} = $self->scroll($self->{errorView});
    $self->{notebook}->append_page($self->{errorScroll}, "Errors");

    # The divide between the graph/error notebook and the text editor is
    # movable.
    my $vpane = new Gtk2::VPaned();
    $vpane->pack1($self->{notebook}, 1, 1);
    $vpane->pack2($self->frame($self->scroll($self->{editorView})), 1, 1);

    my $vbox = new Gtk2::VBox(0, 0);
    $vbox->pack_start($self->{menubar}, 0, 0, 1);
    $vbox->pack_start($vpane, 1, 1, 1);

    $self->{window}->add($vbox);

    return $self;
}

# Called when graphScroll's size allocation is changed
sub graphSizeChanged($$$) {
    my ($self, $widget, $r) = @_;
    my $w = $r->width();
    my $h = $r->height();
    return if(exists $self->{lastGraphWidth}
              and $w == $self->{lastGraphWidth}
              and $h == $self->{lastGraphHeight}); # skip non-changes
    $self->{lastGraphWidth} = $w;
    $self->{lastGraphHeight} = $h;
    $self->redraw(0) if $self->{scale} eq 'fit';
}

# Menu bar --------------------------------------------------------------------

# Create the menu bar
sub createMenuBar($) {
    my $self = shift;

    my $fileMenu = $self->populateMenu
        (new Gtk2::Menu(),
         $self->menuItem('gtk-new',
                         ['n', 'control-mask'],
                         sub { $self->cmdNew(); }),
         $self->menuItem('gtk-open',
                         ['o', 'control-mask'],
                         sub { $self->cmdOpen(); }),
         new Gtk2::SeparatorMenuItem(),
         $self->menuItem('gtk-save',
                         ['s', 'control-mask'],
                         sub { $self->cmdSave(); }),
         $self->menuItem('gtk-save-as',
                         [],
                         sub { $self->cmdSaveAs(); }),
         $self->menuItem('Export',
                         [],
                         sub { $self->cmdExport() }),
         new Gtk2::SeparatorMenuItem(),
         $self->menuItem('gtk-revert-to-saved',
                         [],
                         sub { $self->cmdRevert(); }),
         new Gtk2::SeparatorMenuItem(),
         $self->menuItem('gtk-close',
                         ['w', 'control-mask'],
                         sub { $self->cmdClose(); }),
         $self->menuItem('gtk-quit',
                         ['q', 'control-mask'],
                         sub { $self->cmdQuit(); }));

    my $editMenu = $self->populateMenu
        (new Gtk2::Menu(),
         $self->menuItem('gtk-undo',
                         ['z', 'control-mask'],
                         sub { $self->cmdUndo(); }),
         $self->menuItem('gtk-redo',
                         ['y', 'control-mask'],
                         sub { $self->cmdRedo(); }),
         new Gtk2::SeparatorMenuItem(),
        $self->menuItem('gtk-cut',
                         ['x', 'control-mask'],
                         sub { $self->cmdCut(); }),
         $self->menuItem('gtk-copy',
                         ['c', 'control-mask'],
                         sub { $self->cmdCopy(); }),
         $self->menuItem('gtk-paste',
                         ['v', 'control-mask'],
                         sub { $self->cmdPaste(); }),
         $self->menuItem('gtk-delete',
                         [],
                         sub { $self->cmdDelete(); }),
         new Gtk2::SeparatorMenuItem(),
         $self->menuItem('gtk-select-all',
                         ['a', 'control-mask'],
                         sub { $self->cmdSelectAll() }));

    my $viewMenu = $self->populateMenu
        (new Gtk2::Menu(),
         $self->menuItem('gtk-select-font',
                         [],
                         sub { $self->cmdSelectFont(); }),
         new Gtk2::SeparatorMenuItem(),
         $self->menuItem('gtk-zoom-in',
                         ['equal', 'control-mask'],
                         sub { $self->cmdZoomIn(); }),
         $self->menuItem('gtk-zoom-out',
                         ['minus', 'control-mask'],
                         sub { $self->cmdZoomOut(); }),
         $self->menuItem('gtk-zoom-100',
                         ['0', 'control-mask'],
                         sub { $self->cmdZoom100(); }),
         $self->menuItem('gtk-zoom-fit',
                         ['9', 'control-mask'],
                         sub { $self->cmdZoomFit(); }),
         new Gtk2::SeparatorMenuItem(),
         $self->menuItem('gtk-refresh',
                         ['F5', []],
                         sub { $self->cmdRefresh(); }));

    my $helpMenu = $self->populateMenu
        (new Gtk2::Menu(),
         $self->menuItem('gtk-about',
                         [],
                         sub { $self->cmdAbout(); }));

    $self->{menubar} = $self->populateMenu
        (new Gtk2::MenuBar(),
         $self->menuItem('File',
                         [],
                         $fileMenu),
         $self->menuItem('Edit',
                         [],
                         $editMenu),
         $self->menuItem('View',
                         [],
                         $viewMenu),
         $self->menuItem('Help',
                         [],
                         $helpMenu));

    $self->{"menu-gtk-revert-to-saved"}->set_sensitive(0);

    return $self;
}

# Create a menuitem
sub menuItem($$$$) {
    my $self = shift;
    my $label = shift;                  # stock id/text
    my $key = shift;                    # [KEY,MASK] or KEY or []
    my $action = shift;                 # child menu/subroutine ref
    my $item;
    if($label =~ /^gtk-/) {
        $item = Gtk2::ImageMenuItem->new_from_stock($label);
    } else {
        $item = new Gtk2::MenuItem($label);
    }
    $self->{"menu-$label"} = $item;
    if(ref $key eq 'ARRAY') {
        if(@$key > 0) {
            $item->add_accelerator('activate',
                                   $self->{accelerators},
                                   $Gtk2::Gdk::Keysyms{$key->[0]}, $key->[1],
                                   'visible');
        }
    } else {
        $item->add_accelerator('activate',
                               $self->{accelerators},
                               $Gtk2::Gdk::Keysyms{$key}, [],
                               'visible');
    }
    if(ref $action eq 'CODE') {
        $item->signal_connect("activate" => $action);
    } else {
        $item->set_submenu($action);
    }
    return $item;
}

# Populate a menu
sub populateMenu($$@) {
    my $self = shift;
    my $menuShell = shift;
    for my $menuItem (@_) {
        $menuShell->append($menuItem);
    }
    return $menuShell;
}

# Set widget sensitivities
sub setSensitive($) {
    my $self = shift;
    # File Menu
    $self->{"menu-gtk-revert-to-saved"}->set_sensitive(exists $self->{path});
    # Edit Menu
    my $focus = $self->{window}->get_focus();
    my $selectable = 0;
    my $editable = 0;
    my $selection = 0;
    if(defined $focus and $focus->isa(*Gtk2::TextView)) {
        $selectable = 1;
        $editable = $focus->get_editable();
        $selection = $focus->get_buffer()->get_has_selection();
    }
    $self->{"menu-gtk-cut"}->set_sensitive($editable and $selection);
    $self->{"menu-gtk-copy"}->set_sensitive($selection);
    $self->{"menu-gtk-paste"}->set_sensitive($editable);
    $self->{"menu-gtk-delete"}->set_sensitive($editable and $selection);
    $self->{"menu-gtk-select-all"}->set_sensitive($selectable);
    # View Menu
    $self->{"menu-gtk-zoom-fit"}->set_sensitive($self->{scale} ne 'fit');
    $self->{"menu-gtk-zoom-100"}->set_sensitive($self->{scale} eq 'fit'
                                                or $self->{scale} != 1.0);
}

sub textPaneSetup($$) {
    my ($self, $view) = @_;
    my $buffer = $view->get_buffer();
    $view->signal_connect('focus-in-event',
                          sub {
                              $self->setSensitive();
                          });
    $view->signal_connect('focus-out-event',
                          sub {
                              $self->setSensitive();
                          });
    $buffer->signal_connect('mark-set',
                            sub {
                                $self->setSensitive();
                            });
}

# Display output --------------------------------------------------------------

# Create the graph pane
sub createGraphPane($) {
    my $self = shift;
    $self->{graphImage} = new Gtk2::Image();
    return $self;
}

# Display errors --------------------------------------------------------------

# Create the error pane
sub createErrorPane($) {
    my $self = shift;
    $self->{errorView} = new Gtk2::TextView();
    $self->{errorView}->modify_font($editorFont);
    $self->{errorView}->set_editable(0);
    $self->{errorView}->set_cursor_visible(0);
    $self->{errorView}->signal_connect('populate-popup',
                                       sub {
                                           $self->errorPanelPopup(@_);
                                       });
    $self->{errorBuffer} = $self->{errorView}->get_buffer();
    $self->textPaneSetup($self->{errorView});
    return $self;
}

# Set the current error contents
sub setErrors($@) {
    my $self = shift;
    # Do nothing (including messing with the cursor) if actually nothing
    # has changed.
    my $text = join("", @_);
    my $current = $self->{errorBuffer}->get_text
        ($self->{errorBuffer}->get_start_iter(),
         $self->{errorBuffer}->get_end_iter(),
         0);
    return if $text eq $current;
    $self->{errorBuffer}->delete($self->{errorBuffer}->get_start_iter(),
                                  $self->{errorBuffer}->get_end_iter());
    $self->{errorBuffer}->insert($self->{errorBuffer}->get_start_iter(),
                                 $text);
    $self->{errorBuffer}->place_cursor($self->{errorBuffer}->get_start_iter());
}

# Populate the error panel popup menu
sub errorPanelPopup($$$) {
    my ($self, $view, $menu) = @_;
    my ($w, $x, $y, $mask) = $self->{errorView}->get_window('text')->get_pointer();
    my ($bx, $by) = $self->{errorView}->window_to_buffer_coords('text', $x, $y);
    my $iter = $self->{errorView}->get_iter_at_position($bx, $by);
    $iter->set_line($iter->get_line());
    my $text = $iter->get_text($self->{errorBuffer}->get_end_iter());
    if($text =~/^.*<stdin>:(\d+).*\ncontext: (.*)/) {
        my ($line, $context) = ($1, $2);
        $context =~ s/ >>> //g;
        my $index = index($context, " <<< ");
        my $item = new Gtk2::MenuItem('Jump to error location');
        my $target = $self->{editorBuffer}->get_iter_at_line_index($line - 1,
                                                                   $index);
        $item->signal_connect('activate' =>
                              sub {
                                  $self->{editorBuffer}->place_cursor($target);
                                  $self->{editorView}->scroll_mark_onscreen($self->{editorBuffer}->get_insert());
                                  $self->{editorView}->grab_focus();
                              });
        $menu->insert($item, 0);
        $menu->insert(new Gtk2::SeparatorMenuItem(), 1);
        $menu->show_all();
    }
}

# Edit input ------------------------------------------------------------------

# Create the editing pane
sub createEditingPane($) {
    my $self = shift;
    $self->{editorView} = new Gtk2::SourceView2::View();
    $self->{editorView}->set_show_line_numbers(1);
    $self->{editorView}->modify_font($editorFont);
    $self->{editorView}->set_size_request(-1, 192);
    $self->{editorBuffer} = $self->{editorView}->get_buffer();
    my $lm = Gtk2::SourceView2::LanguageManager->get_default();
    my $language = $lm->get_language("dot");
    $self->{editorBuffer}->set_language($language)
        if defined $language;   # can it ever fail?
    $self->{editorBuffer}->signal_connect('changed' =>
                                          sub {
                                              $self->{lastChange} = Time::HiRes::time();
                                          });
    $self->textPaneSetup($self->{editorView});
    return $self;
}

# Set the font
sub setEditorFont($$) {
    my $self = shift;
    $editorFontName = shift;
    $editorFont = Pango::FontDescription->from_string($editorFontName);
    for my $window (values %windows) {
        $window->{errorView}->modify_font($editorFont);
        $window->{editorView}->modify_font($editorFont);
    }
}

# UI Commands -----------------------------------------------------------------

sub cmdNew($) {
    my $self = shift;
    new Greenend::DotConsole::Window();
}

sub cmdOpen($) {
    my $self = shift;
    # Only create a new window if there's something worth keeping in
    # this window
    my $trivial = ($self->{editorBuffer}->get_char_count() == 0
                   and !exists $self->{path});
    my $chooser = new Gtk2::FileChooserDialog
        ("Open...",
         $self->{window},
         'open',
         'gtk-cancel' => 'cancel',
         'gtk-ok' => 'ok');
    $self->configureFileChooser($chooser);
    if($chooser->run() eq 'ok') {
        my $path = $chooser->get_filename();
        $chooser->destroy();
        if($trivial) {
            $self->openFile($path);
        } else {
            my $window = new Greenend::DotConsole::Window();
            $window->openFile($path) or $window->destroy();
        }
    } else {
        $chooser->destroy();
    }
}

sub cmdSave($) {
    my $self = shift;
    return 1 unless $self->{editorBuffer}->get_modified();
    return $self->cmdSaveAs() unless exists $self->{path};
    return $self->saveFile($self->{path});
}

sub cmdSaveAs($) {
    my $self = shift;
    my $chooser = new Gtk2::FileChooserDialog
        ("Save as...",
         $self->{window},
         'save',
         'gtk-cancel' => 'cancel',
         'gtk-ok' => 'ok');
    $self->configureFileChooser($chooser);
    if($chooser->run() eq 'ok') {
        my $path = $chooser->get_filename();
        $chooser->destroy();
        return $self->saveFile($path);
    } else {
        $chooser->destroy();
        return 0;
    }
}

sub cmdExport($) {
    my $self = shift;
    my $chooser = new Gtk2::FileChooserDialog
        ("Export to...",
         $self->{window},
         'save',
         'gtk-cancel' => 'cancel',
         'gtk-ok' => 'ok');
    $chooser->set_current_folder(defined $self->{path}
                                 ? dirname($self->{path})
                                 : getcwd);
    $chooser->add_filter($self->fileFilter("*.png", "PNG files (*.png)"));
    $chooser->add_filter($self->fileFilter("*.svg", "SVG files (*.svg)"));
    $chooser->add_filter($self->fileFilter("*.ps", "PNG files (*.ps)"));
    $chooser->add_filter($self->fileFilter("*.pdf", "PNG files (*.pdf)"));
    $chooser->set_filename($self->{exportPath})
        if exists $self->{exportPath};
    if($chooser->run() eq 'ok') {
        my $path = $chooser->get_filename();
        $chooser->destroy();
        $self->{exportPath} = $path;
        return $self->exportTo($path);
    } else {
        $chooser->destroy();
        return 0;
    }
}

sub cmdRevert($) {
    my $self = shift;
    $self->openFile($self->{path})
        if exists $self->{path};
}

sub cmdClose($) {
    my $self = shift;
    return unless $self->saveOffer();
    $self->{window}->destroy();
}

sub cmdQuit($) {
    my $self = shift;
    my $modified = 0;
    for my $window (values %windows) {
        ++$modified if $window->{editorBuffer}->get_modified();
    }
    if($modified > 0) {
        my $dialog = new Gtk2::Dialog("Unsaved files",
                                      $self->{window},
                                      'destroy-with-parent',
                                      "Discard" => '1',
                                      'gtk-cancel' => 'cancel');
        $dialog->set_default_response('cancel');
        my $label = new Gtk2::Label("$modified files have been modified.");
        my $hbox = new Gtk2::HBox(0, 0);
        $hbox->pack_start(Gtk2::Image->new_from_stock('gtk-dialog-question',
                                                      'dialog'),
                          0, 0, 1);
        $hbox->pack_start($label, 0, 0, 1);
        $dialog->get_content_area()->add($hbox);
        $dialog->show_all();
        my $response = $dialog->run();
        $dialog->destroy();
        return if $response eq 'cancel';
    }
    Gtk2->main_quit();
}

sub cmdUndo($) {
    my $self = shift;
    $self->{editorView}->signal_emit('undo');
}

sub cmdRedo($) {
    my $self = shift;
    $self->{editorView}->signal_emit('redo');
}

sub cmdCut($) {
    my $self = shift;
    $self->signalFocus('cut-clipboard');
}

sub cmdCopy($) {
    my $self = shift;
    $self->signalFocus('copy-clipboard');
}

sub cmdPaste($) {
    my $self = shift;
    $self->signalFocus('paste-clipboard');
}

sub cmdDelete($) {
    my $self = shift;
    $self->signalFocus('delete-from-cursor', 'chars', 0);
}

sub cmdSelectAll($) {
    my $self = shift;
    $self->signalFocus('select-all', 1);
}

sub cmdSelectFont($) {
    my $self = shift;
    my $dialog = new Gtk2::FontSelectionDialog("Select font");
    $dialog->set_font_name($editorFontName);
    if($dialog->run() eq 'ok') {
        $self->setEditorFont($dialog->get_font_name());
    }
    $dialog->destroy();
}

sub cmdZoomIn($) {
    my $self = shift;
    $self->setScale($self->getScale() * sqrt(2));
}

sub cmdZoomOut($) {
    my $self = shift;
    $self->setScale($self->getScale() / sqrt(2));
}

sub cmdZoomFit($) {
    my $self = shift;
    $self->setScale('fit');
}

sub cmdZoom100($) {
    my $self = shift;
    $self->setScale(1.0);
}

sub cmdRefresh($) {
    my $self = shift;
    $self->render(1);
}

sub cmdAbout($) {
    my $self = shift;
    Gtk2->show_about_dialog($self->{window},
                            "authors" => "Richard Kettlewell",
                            "copyright" => "© 2013 Richard Kettlewell",
                            "license" =>
"This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program.  If not, see <http://www.gnu.org/licenses/>.",
                            "wrap-license" => 1,
                            "program-name" => "dotconsole",
                            "version" => $VERSION,
                            "website" => "https://github.com/ewxrjk/dotconsole");
    # TODO use license-type when upgraded to Gtk3
}

# I/O -------------------------------------------------------------------------

# If the file has been modified, offer to save it.
#
# Returns 1 if it is safe to proceed and 0 otherwise.
sub saveOffer($) {
    my $self = shift;
    return 1 unless $self->{editorBuffer}->get_modified();
    my $dialog = new Gtk2::Dialog("Unsaved files",
                                  $self->{window},
                                  'destroy-with-parent',
                                  'gtk-save' => 'ok',
                                  "Discard" => '1',
                                  'gtk-cancel' => 'cancel');
    $dialog->set_default_response('cancel');
    my $label = new Gtk2::Label
        ((exists $self->{path} ? basename($self->{path}) : "File ")
         . " has been modified.");
    my $hbox = new Gtk2::HBox(0, 0);
    $hbox->pack_start(Gtk2::Image->new_from_stock('gtk-dialog-question',
                                                  'dialog'),
                      0, 0, 1);
    $hbox->pack_start($label, 0, 0, 1);
    $dialog->get_content_area()->add($hbox);
    $dialog->show_all();
    my $response = $dialog->run();
    $dialog->destroy();
    return 0 if $response eq 'cancel';
    return $self->cmdSave() if $response eq 'ok';
    return 1;
}

# Open a named file
#
# Pops up a dialog box on error.
#
# Returns 1 on success, 0 on error.
sub openFile($$) {
    my ($self, $path) = @_;
    my @contents;
    if(!(open(INPUT, "<", $path)
         and (@contents = <INPUT>)
         and (close INPUT))) {
        $self->complain("I/O error", "Reading from $path: $!.");
        return 0;
    }
    $self->{editorBuffer}->delete($self->{editorBuffer}->get_start_iter(),
                                  $self->{editorBuffer}->get_end_iter());
    $self->{editorBuffer}->insert($self->{editorBuffer}->get_start_iter(),
                                  join("", @contents));
    $self->{editorBuffer}->place_cursor($self->{editorBuffer}->get_start_iter());
    $self->setPath($path);
    $self->setModified(0);
    $self->render(0);
    $self->{editorView}->grab_focus();
    return 1;
}

# Save to a named file (which becomes the remembered filename thereafter)
#
# Pops up a dialog box on error.
#
# Returns 1 on success, 0 on error.
sub saveFile($$) {
    my ($self, $path) = @_;
    my $tmp = "$path.tmp";
    if(!($self->store($tmp)
         and (rename $tmp, $path))) {
        $self->complain("I/O error", "Writing to $path: $!.");
        unlink($tmp);
        return 0;
    }
    $self->setPath($path);
    $self->setModified(0);
    return 1;
}

# Return the current editor buffer text
sub currentText($) {
    my $self = shift;
    return $self->{editorBuffer}->get_text
        ($self->{editorBuffer}->get_start_iter(),
         $self->{editorBuffer}->get_end_iter(),
         0);
}

# Store to a named temporary file
#
# Does NOT report errors.
#
# Returns 1 on success, 0 on error.
sub store($$) {
    my ($self, $tmp) = @_;
    if(!(open(OUTPUT, ">", $tmp)
         and (print OUTPUT $self->currentText())
         and (close OUTPUT))) {
        my $saveErrno = $!;
        unlink($tmp);
        $! = $saveErrno;
        return 0;
    }
    return 1;
}

# Set or clear the modified flag
sub setModified($$) {
    my ($self, $modified) = @_;
    $self->{editorBuffer}->set_modified($modified);
    $self->setTitle();
}

# Set the remembered path
sub setPath($$) {
    my ($self, $path) = @_;
    $self->{path} = $path;
    $self->{"menu-gtk-revert-to-saved"}->set_sensitive(1);
    $self->setTitle();
    $self->setSensitive();
}

# Set the window title
sub setTitle($) {
    my $self = shift;
    my $text = "dotconsole";
    if(exists $self->{path}) {
        $text .= ": " . basename($self->{path});
    }
    if($self->{editorBuffer}->get_modified()) {
        $text .= " (modified)";
    }
    $self->{window}->set_title($text);
}

# Rendering -------------------------------------------------------------------

# Set scale to a number or 'fit'
sub setScale($$) {
    my ($self, $scale) = @_;
    $self->{scale} = $scale;
    my $policy = $scale eq 'fit' ? 'never' : 'automatic';
    $self->{graphScroll}->set_policy($policy, $policy);
    $self->redraw(0);
    $self->setSensitive();
}

# Get the current scale
sub getScale($) {
    my $self = shift;
    my $scale = $self->{scale};
    if($scale eq 'fit') {
        my $rw = $self->{rendered}->get_width();
        my $rh = $self->{rendered}->get_height();
        return 1 if !$rw or !$rh;       # avoid /0
        my $ow = $self->{lastGraphWidth};
        my $oh = $self->{lastGraphHeight};
        my $tw = $ow > $rw ? $rw : $ow; # target sizes (1:1 max)
        my $th = $oh > $rh ? $rh : $oh;
        my $sw = $tw / $rw;             # scales for target sizes
        my $sh = $th / $rh;
        return $sw < $sh ? $sw : $sh;   # pick the smaller, so both fit
    }
    return $scale;
}

sub redraw($$) {
    my ($self, $force) = @_;
    return unless exists $self->{rendered};
    my ($w, $h);
    if($self->{scale} ne 'fit' and $self->{scale} == 1.0) { # not scaled!
        $self->{graphImage}->set_from_pixbuf($self->{rendered});
        return;
    }
    # TODO this isn't quite right, 'fit' overflows slightly...
    $w = int($self->{rendered}->get_width() * $self->getScale());
    $h = int($self->{rendered}->get_height() * $self->getScale());
    return if (!$force
               and exists $self->{lastRedrawWidth}
               and $self->{lastRedrawWidth} == $w
               and $self->{lastRedrawHeight} == $h);
    return if $w < 16 or $h < 16;       # tiny sizes cause hangs!
    $self->{displayed} = $self->{rendered}->scale_simple($w, $h, 'hyper');
    $self->{graphImage}->set_from_pixbuf($self->{displayed});
    $self->{lastRedrawWidth} = $w;
    $self->{lastRedrawHeight} = $h;
}

# Called periodically to re-render the current text
sub checkTextChanged($) {
    my $self = shift;
    # Don't attempt to render empty documents
    my $text = $self->currentText();
    return if $text =~ /^\s*$/s;
    if(!exists $self->{lastChange}
       or Time::HiRes::time() - $self->{lastChange} >= 0.5) {
        delete $self->{lastChange};
        $self->render(0);                   # will do nothing if no change
    }
}

# Set up for rendering the current text
sub renderSetup($) {
    my $self = shift;
    my $tmproot = $ENV{TMPDIR} || "/tmp";
    my $tmpdir = "$tmproot/dotconsole.$$.$serial";
    ++$serial;
    my $input = "$tmpdir/input.dot";
    my $output = "$tmpdir/output.png";
    my $errors = "$tmpdir/errors.txt";
    my $rc;
    if(!mkdir($tmpdir, 0700)) {
        return ('', "Creating $tmpdir: $!\n");
    }
    if(!$self->store($input)) {
        return($tmpdir, "Writing to $input: $!\n");
    }
    return ($tmpdir, '');
}

# Render the current text
#
# If there is a rendering job underway then a new one will be started
# as soon as it is complete.
sub render($$) {
    my ($self, $force) = @_;
    # Don't re-render the same text unless forced to
    my $text = $self->currentText();
    if(!$force
       and exists $self->{lastRendered}
       and $text eq $self->{lastRendered}) {
        return;
    }
    # If already rendering, do nothing but instead schedule a new
    # rendering job for when this one completes.
    if(exists $self->{renderPid}) {
        kill(15, $self->{renderPid}) if $force;
        $self->{renderAgain} = 1;
        return;
    }
    # Save the text now.  This means that errors like not being able
    # to create files will be treated as persistent.  The user can
    # bounce on F5 to override (e.g. if they've made more disk space).
    $self->{lastRendered} = $text;
    my ($tmpdir, $error) = $self->renderSetup();
    if($error ne '') {
        $self->renderOutcome(-1, $tmpdir, $error);
        return;
    }
    my $pid = fork();
    if(!defined $pid) {
        $self->renderOutcome(-1, $tmpdir, "fork: $!\n");
        return;
    }
    if($pid == 0) {
        $self->renderChild($tmpdir, 'png', "$tmpdir/output.png");
    }
    $self->{renderPid} = $pid;
    $self->{renderComplete} = sub {
        my $rc = shift;
        delete $self->{renderPid};
        # Retrieve errors
        if(!open(ERRORS, "<", "$tmpdir/errors.txt")) {
            $self->renderOutcome(-1, $tmpdir,
                                 "Reading $tmpdir/errors.txt: $!\n");
            return;
        }
        my @errors = <ERRORS>;
        close ERRORS;
        $self->renderOutcome($rc, $tmpdir, @errors);
    };
}

# Export to some other file type
sub exportTo($$) {
    my ($self, $path) = @_;
    my $ext;
    if($path !~ /\.([^\.]+)$/) {
        return $self->complain("Error", "Cannot guess file type for $path.");
    }
    my $type = $1;
    my ($tmpdir, $error) = $self->renderSetup();
    if($error ne '') {
        $self->renderCleanup($tmpdir);
        return $self->complain("I/O error", "$error.");
    }
    my $pid = fork();
    if(!defined $pid) {
        $self->renderCleanup($tmpdir);
        return $self->complain("System error", "Error calling fork: $!.");
    }
    if($pid == 0) {
        $self->renderChild($tmpdir, $type, $path);
    }
    if(waitpid($pid, 0) != $pid) {
        $self->renderCleanup($tmpdir);
        return $self->complain("System error", "Error calling waitpid: $!");
    }
    if($?) {
        my @errors;
        if(open(ERRORS, "<", "$tmpdir/errors.txt")) {
            @errors = <ERRORS>;
            close ERRORS;
        }
        return $self->complain("Graphiz error", "Graphviz failed (wait status $?).", @errors);
    }
    $self->renderCleanup($tmpdir);
}

# Run inside the rendering child process
sub renderChild($$$) {
    my ($self, $tmpdir, $type, $output) = @_;
    open(STDERR, ">", "$tmpdir/errors.txt")
        or die "ERROR: $tmpdir/errors.txt: $!\n";
    open(STDIN, "<", "$tmpdir/input.dot")
        or die "ERROR: $tmpdir/input.dot: $!\n";
    open(STDOUT, ">", $output)
        or die "ERROR: $output: $!\n";
    exec("dot", "-T$type")
        or die "ERROR: exec dot: $!\n";
}

# Called periodically to check whether rendering has complete
sub checkRenderComplete($) {
    my $self = shift;
    if(exists $self->{renderPid}) {
        return unless waitpid($self->{renderPid}, POSIX::WNOHANG);
        $self->{renderComplete}->($?);
    }
}

# Called when a rendering job completes (or fails)
sub renderOutcome($$$@) {
    my ($self, $rc, $tmpdir, @errors) = @_;
    # Log errors
    $self->setErrors(@errors);
    if($rc == 0) {
        # Retrieve output and display it
        $self->{rendered} = Gtk2::Gdk::Pixbuf->new_from_file("$tmpdir/output.png");
        $self->redraw(1);
        $self->{notebook}->set_current_page(0);
    } else {
        # Display errors
        $self->{notebook}->set_current_page(1);
    }
    $self->renderCleanup($tmpdir);
    if($self->{renderAgain}) {
        $self->{renderAgain} = 0;
        $self->render(0);
    }
}

# Clean up rendering temporary directory
sub renderCleanup($$) {
    my ($self, $tmpdir) = @_;
    if($tmpdir ne '') {
        unlink("$tmpdir/input.dot");
        unlink("$tmpdir/output.png");
        unlink("$tmpdir/errors.txt");
        rmdir($tmpdir);
    }
}

# Utilities -------------------------------------------------------------------

# Put a widget in a frame
sub frame($$) {
    my $self = shift;
    my $widget = shift;
    my $frame = new Gtk2::Frame();
    $frame->set_shadow_type('in');
    $frame->add($widget);
    return $frame;
}

# Make a widget scrollable
sub scroll($$) {
    my $self = shift;
    my $widget = shift;
    my $scroller = new Gtk2::ScrolledWindow();
    $scroller->set_policy('automatic', 'automatic');
    if($widget->isa(*Gtk2::Layout)
       or $widget->isa(*Gtk2::TreeView)
       or $widget->isa(*Gtk2::TextView)
       or $widget->isa(*Gtk2::IconView)
       or $widget->isa(*Gtk2::ToolPalette)
       or $widget->isa(*Gtk2::ViewPort)) { # no 'Scrollable' in Gtk2
        $scroller->add($widget);
    } else {
        $scroller->add_with_viewport($widget);
    }
    return $scroller;
}

# Display an error message
sub complain($$@) {
    my ($self, $primary, $secondary, @details) = @_;
    my $dialog = new Gtk2::MessageDialog
        ($self->{window},
         'destroy-with-parent',
         'error',
         'ok',
         "%s", $primary);
    $dialog->format_secondary_text("%s", $secondary)
        if defined $secondary;
    if(@details > 0) {
        my $view = new Gtk2::TextView();
        $view->modify_font($editorFont);
        $view->set_editable(0);
        $view->set_cursor_visible(0);
        my $buffer = $view->get_buffer();
        $buffer->insert($buffer->get_start_iter(), join("", @details));
        $dialog->get_content_area()->add($self->frame($view));
        $dialog->get_content_area()->show_all();
    }
    $dialog->run();
    $dialog->destroy();
    return $self;
}

# Configure a file chooser for *.dot files
sub configureFileChooser($$) {
    my ($self, $chooser) = @_;
    $chooser->set_current_folder(defined $self->{path}
                                 ? dirname($self->{path})
                                 : getcwd);
    $chooser->add_filter($self->fileFilter("*.dot", "Graphviz files (*.dot)"));
    $chooser->add_filter($self->fileFilter("*", "All files"));
}

# Create a FileFilter
sub fileFilter($$$) {
    my ($self, $pattern, $name) = @_;
    my $filter = new Gtk2::FileFilter();
    $filter->add_pattern($pattern);
    $filter->set_name($name);
    return $filter;
}

# Send a signal to the focused widget, if it supports it
sub signalFocus($@) {
    my ($self, $signal, @args) = @_;
    $self->{window}->get_focus()->signal_emit($signal, @args)
        if defined $self->{window}->get_focus()->signal_query($signal);
}

# -----------------------------------------------------------------------------

return 1;
