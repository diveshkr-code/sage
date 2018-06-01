# cython: old_style_globals=True
# The old_style_globals directive is important for load() to work correctly.
# However, this should be removed in favor of user_globals; see
# https://trac.sagemath.org/ticket/18083
r"""
Object persistence

You can load and save most Sage object to disk using the load and
save member functions and commands.

.. note::

   It is impossible to save certain Sage objects to disk. For example,
   if `x` is a MAGMA object, i.e., a wrapper around an object
   that is defined in MAGMA, there is no way to save `x` it to
   disk, since MAGMA doesn't support saving of individual objects to
   disk.


-  Versions: Loading and saving of objects is guaranteed to work
   even if the version of Python changes. Saved objects can be loaded
   in future versions of Python. However, if the data structure that
   defines the object, e.g., in Sage code, changes drastically (or
   changes name or disappears), then the object might not load
   correctly or work correctly.

-  Objects are zlib compressed for space efficiency.
"""
from __future__ import absolute_import

import os
import sys

# change to import zlib to use zlib instead; but this
# slows down loading any data stored in the other format
import zlib; comp = zlib
import bz2; comp_other = bz2

from six.moves import cPickle
from six.moves import cStringIO as StringIO

from .misc import SAGE_DB
from .sage_unittest import TestSuite


cdef _normalize_filename(s):
    """
    Append the .sobj extension to a filename if it doesn't already have it.
    """
    if s[-5:] != '.sobj':
        return s + '.sobj'

    return s


def load(*filename, compress=True, verbose=True):
    r"""
    Load Sage object from the file with name filename, which will have
    an ``.sobj`` extension added if it doesn't have one.  Or, if the input
    is a filename ending in ``.py``, ``.pyx``, ``.sage``, ``.spyx``,
    ``.f``, ``.f90`` or ``.m``, load that file into the current running
    session.

    Loaded files are not loaded into their own namespace, i.e., this is
    much more like Python's ``execfile`` than Python's ``import``.

    This function also loads a ``.sobj`` file over a network by
    specifying the full URL.  (Setting ``verbose = False`` suppresses
    the loading progress indicator.)

    Finally, if you give multiple positional input arguments, then all
    of those files are loaded, or all of the objects are loaded and a
    list of the corresponding loaded objects is returned.

    EXAMPLES::

        sage: u = 'http://sage.math.washington.edu/home/was/db/test.sobj'
        sage: s = load(u)                                                  # optional - internet
        Attempting to load remote file: http://sage.math.washington.edu/home/was/db/test.sobj
        Loading: [.]
        sage: s                                                            # optional - internet
        'hello SAGE'

    We test loading a file or multiple files or even mixing loading files and objects::

        sage: t = tmp_filename(ext='.py')
        sage: _ = open(t,'w').write("print('hello world')")
        sage: load(t)
        hello world
        sage: load(t,t)
        hello world
        hello world
        sage: t2 = tmp_filename(); save(2/3,t2)
        sage: load(t,t,t2)
        hello world
        hello world
        [None, None, 2/3]

    Files with a ``.sage`` extension are preparsed. Also note that we
    can access global variables::

        sage: t = tmp_filename(ext=".sage")
        sage: with open(t, 'w') as f:
        ....:     _ = f.write("a += Mod(2/3, 11)")  # This evaluates to Mod(8, 11)
        sage: a = -1
        sage: load(t)
        sage: a
        7

    We can load Fortran files::

        sage: code = '      subroutine hello\n         print *, "Hello World!"\n      end subroutine hello\n'
        sage: t = tmp_filename(ext=".F")
        sage: _ = open(t, 'w').write(code)
        sage: load(t)
        sage: hello
        <fortran object>
    """
    import sage.repl.load
    if len(filename) != 1:
        v = [load(file, compress=compress, verbose=verbose) for file in filename]
        # Return v if one of the filenames refers to an object and not
        # a loadable filename.
        for file in filename:
            if not sage.repl.load.is_loadable_filename(file):
                return v
        return

    filename = filename[0]

    if sage.repl.load.is_loadable_filename(filename):
        sage.repl.load.load(filename, globals())
        return

    ## Check if filename starts with "http://" or "https://"
    lower = filename.lower()
    if lower.startswith("http://") or lower.startswith("https://"):
        from sage.misc.remote_file import get_remote_file
        filename = get_remote_file(filename, verbose=verbose)
        tmpfile_flag = True
    else:
        tmpfile_flag = False
        filename = _normalize_filename(filename)

    ## Load file by absolute filename
    X = loads(open(filename).read(), compress=compress)
    try:
        X._default_filename = os.path.abspath(filename)
    except AttributeError:
        pass

    ## Delete the tempfile, if it exists
    if tmpfile_flag:
        os.unlink(filename)

    return X


def _base_save(obj, filename, compress=True):
    """
    Base implementation for dumping an object to a ``.sobj`` file.

    This is the implementation used by :meth:`SageObject.save` and by
    :func:`save` unless the object being saved has a custom ``.save()`` method,
    in which case that is tried first.

    Otherwise this is equivalent to :func:`_base_dumps` just with the resulting
    pickle data saved to a ``.sobj`` file.
    """

    filename = _normalize_filename(filename)

    with open(filename, 'wb') as fobj:
        fobj.write(_base_dumps(obj, compress=compress))

    return filename


def save(obj, filename, compress=True, **kwargs):
    """
    Save ``obj`` to the file with name ``filename``, which will have an
    ``.sobj`` extension added if it doesn't have one and if ``obj``
    doesn't have its own ``save()`` method, like e.g. Python tuples.

    For image objects and the like (which have their own ``save()`` method),
    you may have to specify a specific extension, e.g. ``.png``, if you
    don't want the object to be saved as a Sage object (or likewise, if
    ``filename`` could be interpreted as already having some extension).

    .. WARNING::

       This will *replace* the contents of the file if it already exists.

    EXAMPLES::

        sage: a = matrix(2, [1,2,3,-5/2])
        sage: objfile = os.path.join(SAGE_TMP, 'test.sobj')
        sage: objfile_short = os.path.join(SAGE_TMP, 'test')
        sage: save(a, objfile)
        sage: load(objfile_short)
        [   1    2]
        [   3 -5/2]
        sage: E = EllipticCurve([-1,0])
        sage: P = plot(E)
        sage: save(P, objfile_short)   # saves the plot to "test.sobj"
        sage: save(P, filename=os.path.join(SAGE_TMP, "sage.png"), xmin=-2)
        sage: save(P, os.path.join(SAGE_TMP, "filename.with.some.wrong.ext"))
        Traceback (most recent call last):
        ...
        ValueError: allowed file extensions for images are '.eps', '.pdf', '.pgf', '.png', '.ps', '.sobj', '.svg'!
        sage: print(load(objfile))
        Graphics object consisting of 2 graphics primitives
        sage: save("A python string", os.path.join(SAGE_TMP, 'test'))
        sage: load(objfile)
        'A python string'
        sage: load(objfile_short)
        'A python string'

    TESTS:

    Check that :trac:`11577` is fixed::

        sage: filename = os.path.join(SAGE_TMP, "foo.bar")  # filename containing a dot
        sage: save((1,1),filename)            # saves tuple to "foo.bar.sobj"
        sage: load(filename)
        (1, 1)
    """

    if not os.path.splitext(filename)[1] or not hasattr(obj, 'save'):
        filename = _normalize_filename(filename)

    if filename.endswith('.sobj'):
        try:
            obj.save(filename=filename, compress=compress, **kwargs)
        except (AttributeError, RuntimeError, TypeError):
            _base_save(obj, filename, compress=compress)
    else:
        # Saving an object to an image file.
        obj.save(filename, **kwargs)


def _base_dumps(obj, compress=True):
    """
    Base implementation for dumping an object to a pickle in Sage.

    This is the implementation used by :meth:`SageObject.dumps` and by
    :func:`dumps` unless the object being dumped has a custom ``.dumps()``
    method, in which case that is tried first.
    """

    # the protocol=2 is very important -- this enables saving extensions
    # classes (with no attributes).
    pickle = cPickle.dumps(obj, protocol=2)

    if compress:
        return comp.compress(pickle)

    return pickle


def dumps(obj, compress=True):
    """
    Dump obj to a string s.  To recover obj, use ``loads(s)``.

    .. SEEALSO:: :func:`loads`

    EXAMPLES::

        sage: a = 2/3
        sage: s = dumps(a)
        sage: len(s)
        49
        sage: loads(s)
        2/3
    """
    if make_pickle_jar:
        picklejar(obj)
    try:
        return obj.dumps(compress)
    except (AttributeError, RuntimeError, TypeError):
        return _base_dumps(obj, compress=compress)


# This is used below, and also by explain_pickle.py
unpickle_override = {}

def register_unpickle_override(module, name, callable, call_name=None):
    r"""
    Python pickles include the module and class name of classes.
    This means that rearranging the Sage source can invalidate old
    pickles.  To keep the old pickles working, you can call
    register_unpickle_override with an old module name and class name,
    and the Python callable (function, class with __call__ method, etc.)
    to use for unpickling.  (If this callable is a value in some module,
    you can specify the module name and class name, for the benefit of
    :func:`~sage.misc.explain_pickle.explain_pickle` when called with ``in_current_sage=True``).)

    EXAMPLES:

    Imagine that there used to be an ``old_integer`` module and old
    pickles essentially trying to do the following::

        sage: unpickle_global('sage.rings.old_integer', 'OldInteger')
        Traceback (most recent call last):
        ...
        ImportError: cannot import OldInteger from sage.rings.old_integer, call register_unpickle_override('sage.rings.old_integer', 'OldInteger', ...) to fix this

    After following the advice from the error message, unpickling
    works::

        sage: from sage.misc.persist import register_unpickle_override
        sage: register_unpickle_override('sage.rings.old_integer', 'OldInteger', Integer)
        sage: unpickle_global('sage.rings.old_integer', 'OldInteger')
        <... 'sage.rings.integer.Integer'>

    In many cases, unpickling problems for old pickles can be resolved with a
    simple call to ``register_unpickle_override``, as in the example above and
    in many of the ``sage`` source files.  However, if the underlying data
    structure has changed significantly then unpickling may fail and it
    will be necessary to explicitly implement unpickling methods for the
    associated objects. The python pickle protocol is described in detail on the
    web and, in particular, in the `python pickling documentation`_. For example, the
    following excerpt from this documentation shows that the unpickling of
    classes is controlled by their :meth:`__setstate__` method.

    ::

        object.__setstate__(state)

            Upon unpickling, if the class also defines the method :meth:`__setstate__`, it is
            called with the unpickled state. If there is no :meth:`__setstate__` method,
            the pickled state must be a dictionary and its items are assigned to the new
            instance's dictionary. If a class defines both :meth:`getstate__` and
            :meth:`__setstate__`, the state object needn't be a dictionary and these methods
            can do what they want.

    .. _python pickling documentation: http://docs.python.org/library/pickle.html#pickle-protocol

    By implementing a :meth:`__setstate__` method for a class it should be
    possible to fix any unpickling problems for the class. As an example of what
    needs to be done, we show how to unpickle a :class:`CombinatorialObject`
    object using a class which also inherits from
    :class:`~sage.structure.element.Element`. This exact problem often arises
    when refactoring old code into the element framework. First we create a
    pickle to play with::

        sage: from sage.structure.element import Element
        sage: class SourPickle(CombinatorialObject): pass
        sage: class SweetPickle(CombinatorialObject,Element): pass
        sage: import __main__
        sage: __main__.SourPickle=SourPickle
        sage: __main__.SweetPickle=SweetPickle  # a hack to allow us to pickle command line classes
        sage: gherkin = dumps( SourPickle([1,2,3]) )

    Using :func:`register_unpickle_override` we try to sweeten our pickle, but we are unable to eat it::

        sage: from sage.misc.persist import register_unpickle_override
        sage: register_unpickle_override('__main__','SourPickle',SweetPickle)
        sage: loads( gherkin )
        Traceback (most recent call last):
        ...
        KeyError: 0

    The problem is that the ``SweetPickle`` has inherited a
    :meth:`~sage.structure.element.Element.__setstate__` method from
    :class:`~sage.structure.element.Element` which is not compatible with
    unpickling for :class:`CombinatorialObject`. We can fix this by explicitly
    defining a new :meth:`__setstate__` method::

        sage: class SweeterPickle(CombinatorialObject,Element):
        ....:     def __setstate__(self, state):
        ....:         if isinstance(state, dict):       # a pickle from CombinatorialObject is just its instance dictionary
        ....:             self._set_parent(Tableaux())  # this is a fudge: we need an appropriate parent here
        ....:             self.__dict__ = state
        ....:         else:
        ....:             P, D = state
        ....:             if P is not None:
        ....:                 self._set_parent(P)
        ....:             self.__dict__ = D
        sage: __main__.SweeterPickle = SweeterPickle
        sage: register_unpickle_override('__main__','SourPickle',SweeterPickle)
        sage: loads( gherkin )
        [1, 2, 3]
        sage: loads(dumps( SweeterPickle([1,2,3]) ))   # check that pickles work for SweeterPickle
        [1, 2, 3]

    The ``state`` passed to :meth:`__setstate__` will usually be something like
    the instance dictionary of the pickled object, however, with some older
    classes such as :class:`CombinatorialObject` it will be a tuple. In general,
    the ``state`` can be any python object.  ``Sage`` provides a special tool,
    :func:`~sage.misc.explain_pickle.explain_pickle`, which can help in figuring
    out the contents of an old pickle. Here is a second example.

    ::

        sage: class A(object):
        ....:    def __init__(self,value):
        ....:        self.original_attribute = value
        ....:    def __repr__(self):
        ....:        return 'A(%s)'%self.original_attribute
        sage: class B(object):
        ....:    def __init__(self,value):
        ....:        self.new_attribute = value
        ....:    def __setstate__(self,state):
        ....:        try:
        ....:            self.new_attribute = state['new_attribute']
        ....:        except KeyError:      # an old pickle
        ....:            self.new_attribute = state['original_attribute']
        ....:    def __repr__(self):
        ....:        return 'B(%s)'%self.new_attribute
        sage: import __main__
        sage: __main__.A=A; __main__.B=B  # a hack to allow us to pickle command line classes
        sage: A(10)
        A(10)
        sage: loads( dumps(A(10)) )
        A(10)
        sage: sage.misc.explain_pickle.explain_pickle( dumps(A(10)) )
        pg_A = unpickle_global('__main__', 'A')
        si = unpickle_newobj(pg_A, ())
        pg_make_integer = unpickle_global('sage.rings.integer', 'make_integer')
        unpickle_build(si, {'original_attribute':pg_make_integer('a')})
        si
        sage: from sage.misc.persist import register_unpickle_override
        sage: register_unpickle_override('__main__', 'A', B)
        sage: loads( dumps(A(10)) )
        B(10)
        sage: loads( dumps(B(10)) )
        B(10)

    Pickling for python classes and extension classes, such as cython, is
    different -- again this is discussed in the `python pickling documentation`_. For the
    unpickling of extension classes you need to write a :meth:`__reduce__`
    method which typically returns a tuple ``(f, args,...)`` such that
    ``f(*args)`` returns (a copy of) the original object. The following code
    snippet is the :meth:`~sage.rings.integer.Integer.__reduce__` method from
    :class:`sage.rings.integer.Integer`.

    .. code-block:: cython

        def __reduce__(self):
            'Including the documentation properly causes a doc-test failure so we include it as a comment:'
            #* '''
            #* This is used when pickling integers.
            #*
            #* EXAMPLES::
            #*
            #*     sage: n = 5
            #*     sage: t = n.__reduce__(); t
            #*     (<built-in function make_integer>, ('5',))
            #*     sage: t[0](*t[1])
            #*     5
            #*     sage: loads(dumps(n)) == n
            #*     True
            #* '''
            # This single line below took me HOURS to figure out.
            # It is the *trick* needed to pickle Cython extension types.
            # The trick is that you must put a pure Python function
            # as the first argument, and that function must return
            # the result of unpickling with the argument in the second
            # tuple as input. All kinds of problems happen
            # if we don't do this.
            return sage.rings.integer.make_integer, (self.str(32),)

    """
    unpickle_override[(module,name)] = (callable, call_name)


def unpickle_global(module, name):
    r"""
    Given a module name and a name within that module (typically a class
    name), retrieve the corresponding object.  This normally just looks
    up the name in the module, but it can be overridden by
    register_unpickle_override.  This is used in the Sage unpickling
    mechanism, so if the Sage source code organization changes,
    register_unpickle_override can allow old pickles to continue to work.

    EXAMPLES::

        sage: from sage.misc.persist import unpickle_override, register_unpickle_override
        sage: unpickle_global('sage.rings.integer', 'Integer')
        <... 'sage.rings.integer.Integer'>

    Now we horribly break the pickling system::

        sage: register_unpickle_override('sage.rings.integer', 'Integer', Rational, call_name=('sage.rings.rational', 'Rational'))
        sage: unpickle_global('sage.rings.integer', 'Integer')
        <... 'sage.rings.rational.Rational'>

    and we reach into the internals and put it back::

        sage: del unpickle_override[('sage.rings.integer', 'Integer')]
        sage: unpickle_global('sage.rings.integer', 'Integer')
        <... 'sage.rings.integer.Integer'>

    A meaningful error message with resolution instructions is displayed for
    old pickles that accidentally got broken because a class or entire module
    was moved or renamed::

        sage: unpickle_global('sage.all', 'some_old_class')
        Traceback (most recent call last):
        ...
        ImportError: cannot import some_old_class from sage.all, call
        register_unpickle_override('sage.all', 'some_old_class', ...)
        to fix this

        sage: unpickle_global('sage.some_old_module', 'some_old_class')
        Traceback (most recent call last):
        ...
        ImportError: cannot import some_old_class from sage.some_old_module, call
        register_unpickle_override('sage.some_old_module', 'some_old_class', ...)
        to fix this
    """
    unpickler = unpickle_override.get((module, name))
    if unpickler is not None:
        return unpickler[0]

    def error():
        raise ImportError("cannot import {1} from {0}, call "
            "register_unpickle_override({0!r}, {1!r}, ...) to fix this".format(
                module, name))

    mod = sys.modules.get(module)
    if mod is not None:
        try:
            return getattr(mod, name)
        except AttributeError:
            error()
    try:
        __import__(module)
    except ImportError:
        error()
    mod = sys.modules[module]
    return getattr(mod, name)


def loads(s, compress=True):
    """
    Recover an object x that has been dumped to a string s
    using ``s = dumps(x)``.

    .. SEEALSO:: :func:`dumps`

    EXAMPLES::

        sage: a = matrix(2, [1,2,3,-4/3])
        sage: s = dumps(a)
        sage: loads(s)
        [   1    2]
        [   3 -4/3]

    If compress is True (the default), it will try to decompress
    the data with zlib and with bz2 (in turn); if neither succeeds,
    it will assume the data is actually uncompressed.  If compress=False
    is explicitly specified, then no decompression is attempted.

    ::

        sage: v = [1..10]
        sage: loads(dumps(v, compress=False)) == v
        True
        sage: loads(dumps(v, compress=False), compress=True) == v
        True
        sage: loads(dumps(v, compress=True), compress=False)
        Traceback (most recent call last):
        ...
        UnpicklingError: invalid load key, 'x'.
    """
    if not isinstance(s, str):
        raise TypeError("s must be a string")
    if compress:
        try:
            s = comp.decompress(s)
        except Exception as msg1:
            try:
                s = comp_other.decompress(s)
            except Exception as msg2:
                # Maybe data is uncompressed?
                pass

    unpickler = cPickle.Unpickler(StringIO(s))
    unpickler.find_global = unpickle_global

    return unpickler.load()


cdef bint make_pickle_jar = 'SAGE_PICKLE_JAR' in os.environ

def picklejar(obj, dir=None):
    """
    Create pickled sobj of ``obj`` in ``dir``, with name the absolute
    value of the hash of the pickle of obj.  This is used in conjunction
    with :func:`unpickle_all`.

    To use this to test the whole Sage library right now, set the
    environment variable ``SAGE_PICKLE_JAR``, which will make it so
    :func:`dumps` will by default call :func:`picklejar` with the
    default dir.  Once you do that and doctest Sage, you'll find that
    the ``SAGE_ROOT/tmp/pickle_jar`` directory contains a bunch of
    pickled objects along with corresponding txt descriptions of them.
    Use the :func:`unpickle_all` to see if they unpickle later.

    INPUT:

    - ``obj`` -- a pickleable object

    - ``dir`` -- a string or None; if None then ``dir`` defaults to
      ``SAGE_ROOT/tmp/pickle_jar``

    EXAMPLES::

        sage: dir = tmp_dir()
        sage: sage.misc.persist.picklejar(1, dir)
        sage: sage.misc.persist.picklejar('test', dir)
        sage: len(os.listdir(dir))   # Two entries (sobj and txt) for each object
        4

    TESTS:

    Test an unaccessible directory::

        sage: import os, sys
        sage: os.chmod(dir, 0o000)
        sage: try:
        ....:     uid = os.getuid()
        ....: except AttributeError:
        ....:     uid = -1
        sage: if uid==0:
        ....:     raise OSError('You must not run the doctests as root, geez!')
        ....: elif sys.platform == 'cygwin':
        ....:     raise OSError("This won't always behave on Cygwin depending on permission handling configuration.")
        ....: else:
        ....:     sage.misc.persist.picklejar(1, dir + '/noaccess')
        Traceback (most recent call last):
        ...
        OSError: ...
        sage: os.chmod(dir, 0o755)
    """
    if dir is None:
        dir = os.environ['SAGE_ROOT'] + '/tmp/pickle_jar/'
    try:
        os.makedirs(dir)
    except OSError as err:
        # It is not an error if the directory exists
        import errno
        if not err.errno == errno.EEXIST:
            raise

    s = comp.compress(cPickle.dumps(obj,protocol=2))

    typ = str(type(obj))
    name = ''.join([x if (x.isalnum() or x == '_') else '_' for x in typ])
    base = '%s/%s'%(dir, name)
    if os.path.exists(base):
        i = 0
        while os.path.exists(base + '-%s'%i):
            i += 1
        base += '-%s'%i

    open(base + '.sobj', 'wb').write(s)
    txt = "type(obj) = %s\n"%typ
    import sage.version
    txt += "version = %s\n"%sage.version.version
    txt += "obj =\n'%s'\n"%str(obj)

    open(base + '.txt', 'w').write(txt)


def unpickle_all(dir, debug=False, run_test_suite=False):
    """
    Unpickle all sobj's in the given directory, reporting failures as
    they occur.  Also printed the number of successes and failure.

    INPUT:

    - ``dir`` -- a string; the name of a directory (or of a .tar.bz2
      file that decompresses to a directory) full of pickles.
    - ``debug`` -- a boolean (default: False)
      whether to report a stacktrace in case of failure
    - ``run_test_suite`` -- a boolean (default: False)
      whether to run ``TestSuite(x).run()`` on the unpickled objects

    EXAMPLES::

        sage: dir = tmp_dir()
        sage: sage.misc.persist.picklejar('hello', dir)
        sage: sage.misc.persist.unpickle_all(dir)
        Successfully unpickled 1 objects.
        Failed to unpickle 0 objects.
    """
    i = 0
    j = 0
    failed = []
    tracebacks = []
    # This could use instead Python's tarfile module
    if dir.endswith('.tar.bz2'):
        # create a temporary directory
        from sage.misc.all import tmp_dir
        T = tmp_dir()
        # extract tarball to it
        os.system('cd "%s"; bunzip2 -c "%s" | tar fx - '%(T, os.path.abspath(dir)))
        # Now use the directory in the tarball instead of dir
        dir = T + "/" + os.listdir(T)[0]

    for A in sorted(os.listdir(dir)):
        if A.endswith('.sobj'):
            try:
                obj = load(os.path.join(dir,A))
                if run_test_suite:
                    TestSuite(obj).run(catch = False)
                i += 1
            except Exception:
                j += 1
                if run_test_suite:
                    print(" * unpickle failure: TestSuite(load('%s')).run()" % os.path.join(dir, A))
                else:
                    print(" * unpickle failure: load('%s')" % os.path.join(dir, A))
                from traceback import print_exc
                print_exc()
                failed.append(A)
                if debug:
                    tracebacks.append(sys.exc_info())

    if len(failed) > 0:
        print("Failed:\n%s" % ('\n'.join(failed)))
    print("Successfully unpickled %s objects." % i)
    print("Failed to unpickle %s objects." % j)
    if debug:
        return tracebacks


def make_None(*args, **kwds):
    """
    Do nothing and return ``None``. Used for overriding pickles when
    that pickle is no longer needed.

    EXAMPLES::

        sage: from sage.misc.persist import make_None
        sage: print(make_None(42, pi, foo='bar'))
        None
    """
    return None


# Generators is no longer used (#21382)
register_unpickle_override('sage.structure.generators', 'make_list_gens', make_None)


def load_sage_object(cls, dic):   # not used
    X = cls.__new__(cls)
    try:
        X.__setstate__(dic)
    except AttributeError:
        X.__dict__ = dic
    return X


def load_sage_element(cls, parent, dic_pic):
    X = cls.__new__(cls)
    X._set_parent(parent)
    X.__dict__ = cPickle.loads(dic_pic)
    return X


def db(name):
    r"""
    Load object with given name from the Sage database. Use x.db(name)
    or db_save(x, name) to save objects to the database.

    The database directory is ``$HOME/.sage/db``.
    """
    return load('%s/%s'%(SAGE_DB,name))


def db_save(x, name=None):
    r"""
    Save x to the Sage database.

    The database directory is ``$HOME/.sage/db``.
    """
    try:
        x.db(name)
    except AttributeError:
        save(x, '%s/%s'%(SAGE_DB,name))