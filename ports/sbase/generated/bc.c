/* A Bison parser, made by GNU Bison 3.8.2.  */

/* Bison implementation for Yacc-like parsers in C

   Copyright (C) 1984, 1989-1990, 2000-2015, 2018-2021 Free Software Foundation,
   Inc.

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <https://www.gnu.org/licenses/>.  */

/* As a special exception, you may create a larger work that contains
   part or all of the Bison parser skeleton and distribute that work
   under terms of your choice, so long as that work isn't itself a
   parser generator using the skeleton or a modified version thereof
   as a parser skeleton.  Alternatively, if you modify or redistribute
   the parser skeleton itself, you may (at your option) remove this
   special exception, which will cause the skeleton and the resulting
   Bison output files to be licensed under the GNU General Public
   License without this special exception.

   This special exception was added by the Free Software Foundation in
   version 2.2 of Bison.  */

/* C LALR(1) parser skeleton written by Richard Stallman, by
   simplifying the original so-called "semantic" parser.  */

/* DO NOT RELY ON FEATURES THAT ARE NOT DOCUMENTED in the manual,
   especially those whose name start with YY_ or yy_.  They are
   private implementation details that can be changed or removed.  */

/* All symbols defined below should begin with yy or YY, to avoid
   infringing on user name space.  This should be done even for local
   variables, as they might otherwise be expanded by user macros.
   There are some unavoidable exceptions within include files to
   define necessary library symbols; they are noted "INFRINGES ON
   USER NAME SPACE" below.  */

/* Identify Bison output, and Bison version.  */
#define YYBISON 30802

/* Bison version string.  */
#define YYBISON_VERSION "3.8.2"

/* Skeleton name.  */
#define YYSKELETON_NAME "yacc.c"

/* Pure parsers.  */
#define YYPURE 0

/* Push parsers.  */
#define YYPUSH 0

/* Pull parsers.  */
#define YYPULL 1




/* First part of user prologue.  */
#line 1 "bc.y"

#include <libgen.h>
#include <unistd.h>

#include <assert.h>
#include <ctype.h>
#include <errno.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "arg.h"
#include "util.h"

#define DIGITS   "0123456789ABCDEF"
#define NESTED_MAX 32

#define funid(f) ((f)[0] - 'a' + 1)

int yydebug;

typedef struct macro Macro;

struct macro {
	int op;
	int id;
	char *name;
	int flowid;
	int nested;
};

static int yyerror(char *);
static int yylex(void);

static void quit(void);
static char *code(char *, ...);
static char *forcode(Macro *, char *, char *, char *, char *);
static char *whilecode(Macro *, char *, char *);
static char *ifcode(Macro *, char *, char *);
static char *funcode(Macro *, char *, char *, char *);
static char *param(char *, char *), *local(char *, char *);
static Macro *define(char *, char *);
static char *retcode(char *);
static char *brkcode(void);
static Macro *macro(int);

static char *ftn(char *);
static char *var(char *);
static char *ary(char *);
static void writeout(char *);

static char *yytext, *buff, *unwind;
static char *filename;
static FILE *filep;
static int lineno, nerr, flowid;
static jmp_buf recover;
static int nested, inhome;
static Macro macros[NESTED_MAX];
int cflag, dflag, lflag, sflag;

static char *dcprog = "dc";


#line 137 "bc.c"

# ifndef YY_CAST
#  ifdef __cplusplus
#   define YY_CAST(Type, Val) static_cast<Type> (Val)
#   define YY_REINTERPRET_CAST(Type, Val) reinterpret_cast<Type> (Val)
#  else
#   define YY_CAST(Type, Val) ((Type) (Val))
#   define YY_REINTERPRET_CAST(Type, Val) ((Type) (Val))
#  endif
# endif
# ifndef YY_NULLPTR
#  if defined __cplusplus
#   if 201103L <= __cplusplus
#    define YY_NULLPTR nullptr
#   else
#    define YY_NULLPTR 0
#   endif
#  else
#   define YY_NULLPTR ((void*)0)
#  endif
# endif


/* Debug traces.  */
#ifndef YYDEBUG
# define YYDEBUG 0
#endif
#if YYDEBUG
extern int yydebug;
#endif

/* Token kinds.  */
#ifndef YYTOKENTYPE
# define YYTOKENTYPE
  enum yytokentype
  {
    YYEMPTY = -2,
    YYEOF = 0,                     /* "end of file"  */
    YYerror = 256,                 /* error  */
    YYUNDEF = 257,                 /* "invalid token"  */
    ID = 258,                      /* ID  */
    STRING = 259,                  /* STRING  */
    NUMBER = 260,                  /* NUMBER  */
    EQOP = 261,                    /* EQOP  */
    INCDEC = 262,                  /* INCDEC  */
    HOME = 263,                    /* HOME  */
    LOOP = 264,                    /* LOOP  */
    DOT = 265,                     /* DOT  */
    EQ = 266,                      /* EQ  */
    LE = 267,                      /* LE  */
    GE = 268,                      /* GE  */
    NE = 269,                      /* NE  */
    DEF = 270,                     /* DEF  */
    BREAK = 271,                   /* BREAK  */
    QUIT = 272,                    /* QUIT  */
    LENGTH = 273,                  /* LENGTH  */
    RETURN = 274,                  /* RETURN  */
    FOR = 275,                     /* FOR  */
    IF = 276,                      /* IF  */
    WHILE = 277,                   /* WHILE  */
    SQRT = 278,                    /* SQRT  */
    SCALE = 279,                   /* SCALE  */
    IBASE = 280,                   /* IBASE  */
    OBASE = 281,                   /* OBASE  */
    AUTO = 282,                    /* AUTO  */
    PARAM = 283,                   /* PARAM  */
    PRINT = 284                    /* PRINT  */
  };
  typedef enum yytokentype yytoken_kind_t;
#endif
/* Token kinds.  */
#define YYEMPTY -2
#define YYEOF 0
#define YYerror 256
#define YYUNDEF 257
#define ID 258
#define STRING 259
#define NUMBER 260
#define EQOP 261
#define INCDEC 262
#define HOME 263
#define LOOP 264
#define DOT 265
#define EQ 266
#define LE 267
#define GE 268
#define NE 269
#define DEF 270
#define BREAK 271
#define QUIT 272
#define LENGTH 273
#define RETURN 274
#define FOR 275
#define IF 276
#define WHILE 277
#define SQRT 278
#define SCALE 279
#define IBASE 280
#define OBASE 281
#define AUTO 282
#define PARAM 283
#define PRINT 284

/* Value type.  */
#if ! defined YYSTYPE && ! defined YYSTYPE_IS_DECLARED
union YYSTYPE
{
#line 67 "bc.y"

	char *str;
	char id[2];
	Macro *macro;

#line 251 "bc.c"

};
typedef union YYSTYPE YYSTYPE;
# define YYSTYPE_IS_TRIVIAL 1
# define YYSTYPE_IS_DECLARED 1
#endif


extern YYSTYPE yylval;


int yyparse (void);



/* Symbol kind.  */
enum yysymbol_kind_t
{
  YYSYMBOL_YYEMPTY = -2,
  YYSYMBOL_YYEOF = 0,                      /* "end of file"  */
  YYSYMBOL_YYerror = 1,                    /* error  */
  YYSYMBOL_YYUNDEF = 2,                    /* "invalid token"  */
  YYSYMBOL_ID = 3,                         /* ID  */
  YYSYMBOL_STRING = 4,                     /* STRING  */
  YYSYMBOL_NUMBER = 5,                     /* NUMBER  */
  YYSYMBOL_EQOP = 6,                       /* EQOP  */
  YYSYMBOL_7_ = 7,                         /* '+'  */
  YYSYMBOL_8_ = 8,                         /* '-'  */
  YYSYMBOL_9_ = 9,                         /* '*'  */
  YYSYMBOL_10_ = 10,                       /* '/'  */
  YYSYMBOL_11_ = 11,                       /* '%'  */
  YYSYMBOL_12_ = 12,                       /* '^'  */
  YYSYMBOL_INCDEC = 13,                    /* INCDEC  */
  YYSYMBOL_HOME = 14,                      /* HOME  */
  YYSYMBOL_LOOP = 15,                      /* LOOP  */
  YYSYMBOL_DOT = 16,                       /* DOT  */
  YYSYMBOL_EQ = 17,                        /* EQ  */
  YYSYMBOL_LE = 18,                        /* LE  */
  YYSYMBOL_GE = 19,                        /* GE  */
  YYSYMBOL_NE = 20,                        /* NE  */
  YYSYMBOL_DEF = 21,                       /* DEF  */
  YYSYMBOL_BREAK = 22,                     /* BREAK  */
  YYSYMBOL_QUIT = 23,                      /* QUIT  */
  YYSYMBOL_LENGTH = 24,                    /* LENGTH  */
  YYSYMBOL_RETURN = 25,                    /* RETURN  */
  YYSYMBOL_FOR = 26,                       /* FOR  */
  YYSYMBOL_IF = 27,                        /* IF  */
  YYSYMBOL_WHILE = 28,                     /* WHILE  */
  YYSYMBOL_SQRT = 29,                      /* SQRT  */
  YYSYMBOL_SCALE = 30,                     /* SCALE  */
  YYSYMBOL_IBASE = 31,                     /* IBASE  */
  YYSYMBOL_OBASE = 32,                     /* OBASE  */
  YYSYMBOL_AUTO = 33,                      /* AUTO  */
  YYSYMBOL_PARAM = 34,                     /* PARAM  */
  YYSYMBOL_PRINT = 35,                     /* PRINT  */
  YYSYMBOL_36_ = 36,                       /* '='  */
  YYSYMBOL_37_n_ = 37,                     /* '\n'  */
  YYSYMBOL_38_ = 38,                       /* '{'  */
  YYSYMBOL_39_ = 39,                       /* '}'  */
  YYSYMBOL_40_ = 40,                       /* ';'  */
  YYSYMBOL_41_ = 41,                       /* ','  */
  YYSYMBOL_42_ = 42,                       /* '('  */
  YYSYMBOL_43_ = 43,                       /* ')'  */
  YYSYMBOL_44_ = 44,                       /* '['  */
  YYSYMBOL_45_ = 45,                       /* ']'  */
  YYSYMBOL_46_ = 46,                       /* '<'  */
  YYSYMBOL_47_ = 47,                       /* '>'  */
  YYSYMBOL_YYACCEPT = 48,                  /* $accept  */
  YYSYMBOL_program = 49,                   /* program  */
  YYSYMBOL_item = 50,                      /* item  */
  YYSYMBOL_function = 51,                  /* function  */
  YYSYMBOL_scolonlst = 52,                 /* scolonlst  */
  YYSYMBOL_statlst = 53,                   /* statlst  */
  YYSYMBOL_stat = 54,                      /* stat  */
  YYSYMBOL_while = 55,                     /* while  */
  YYSYMBOL_if = 56,                        /* if  */
  YYSYMBOL_for = 57,                       /* for  */
  YYSYMBOL_def = 58,                       /* def  */
  YYSYMBOL_parlst = 59,                    /* parlst  */
  YYSYMBOL_params = 60,                    /* params  */
  YYSYMBOL_param = 61,                     /* param  */
  YYSYMBOL_autolst = 62,                   /* autolst  */
  YYSYMBOL_locals = 63,                    /* locals  */
  YYSYMBOL_local = 64,                     /* local  */
  YYSYMBOL_arglst = 65,                    /* arglst  */
  YYSYMBOL_cond = 66,                      /* cond  */
  YYSYMBOL_rel = 67,                       /* rel  */
  YYSYMBOL_exprstat = 68,                  /* exprstat  */
  YYSYMBOL_expr = 69,                      /* expr  */
  YYSYMBOL_nexpr = 70,                     /* nexpr  */
  YYSYMBOL_assign = 71,                    /* assign  */
  YYSYMBOL_ary = 72                        /* ary  */
};
typedef enum yysymbol_kind_t yysymbol_kind_t;




#ifdef short
# undef short
#endif

/* On compilers that do not define __PTRDIFF_MAX__ etc., make sure
   <limits.h> and (if available) <stdint.h> are included
   so that the code can choose integer types of a good width.  */

#ifndef __PTRDIFF_MAX__
# include <limits.h> /* INFRINGES ON USER NAME SPACE */
# if defined __STDC_VERSION__ && 199901 <= __STDC_VERSION__
#  include <stdint.h> /* INFRINGES ON USER NAME SPACE */
#  define YY_STDINT_H
# endif
#endif

/* Narrow types that promote to a signed type and that can represent a
   signed or unsigned integer of at least N bits.  In tables they can
   save space and decrease cache pressure.  Promoting to a signed type
   helps avoid bugs in integer arithmetic.  */

#ifdef __INT_LEAST8_MAX__
typedef __INT_LEAST8_TYPE__ yytype_int8;
#elif defined YY_STDINT_H
typedef int_least8_t yytype_int8;
#else
typedef signed char yytype_int8;
#endif

#ifdef __INT_LEAST16_MAX__
typedef __INT_LEAST16_TYPE__ yytype_int16;
#elif defined YY_STDINT_H
typedef int_least16_t yytype_int16;
#else
typedef short yytype_int16;
#endif

/* Work around bug in HP-UX 11.23, which defines these macros
   incorrectly for preprocessor constants.  This workaround can likely
   be removed in 2023, as HPE has promised support for HP-UX 11.23
   (aka HP-UX 11i v2) only through the end of 2022; see Table 2 of
   <https://h20195.www2.hpe.com/V2/getpdf.aspx/4AA4-7673ENW.pdf>.  */
#ifdef __hpux
# undef UINT_LEAST8_MAX
# undef UINT_LEAST16_MAX
# define UINT_LEAST8_MAX 255
# define UINT_LEAST16_MAX 65535
#endif

#if defined __UINT_LEAST8_MAX__ && __UINT_LEAST8_MAX__ <= __INT_MAX__
typedef __UINT_LEAST8_TYPE__ yytype_uint8;
#elif (!defined __UINT_LEAST8_MAX__ && defined YY_STDINT_H \
       && UINT_LEAST8_MAX <= INT_MAX)
typedef uint_least8_t yytype_uint8;
#elif !defined __UINT_LEAST8_MAX__ && UCHAR_MAX <= INT_MAX
typedef unsigned char yytype_uint8;
#else
typedef short yytype_uint8;
#endif

#if defined __UINT_LEAST16_MAX__ && __UINT_LEAST16_MAX__ <= __INT_MAX__
typedef __UINT_LEAST16_TYPE__ yytype_uint16;
#elif (!defined __UINT_LEAST16_MAX__ && defined YY_STDINT_H \
       && UINT_LEAST16_MAX <= INT_MAX)
typedef uint_least16_t yytype_uint16;
#elif !defined __UINT_LEAST16_MAX__ && USHRT_MAX <= INT_MAX
typedef unsigned short yytype_uint16;
#else
typedef int yytype_uint16;
#endif

#ifndef YYPTRDIFF_T
# if defined __PTRDIFF_TYPE__ && defined __PTRDIFF_MAX__
#  define YYPTRDIFF_T __PTRDIFF_TYPE__
#  define YYPTRDIFF_MAXIMUM __PTRDIFF_MAX__
# elif defined PTRDIFF_MAX
#  ifndef ptrdiff_t
#   include <stddef.h> /* INFRINGES ON USER NAME SPACE */
#  endif
#  define YYPTRDIFF_T ptrdiff_t
#  define YYPTRDIFF_MAXIMUM PTRDIFF_MAX
# else
#  define YYPTRDIFF_T long
#  define YYPTRDIFF_MAXIMUM LONG_MAX
# endif
#endif

#ifndef YYSIZE_T
# ifdef __SIZE_TYPE__
#  define YYSIZE_T __SIZE_TYPE__
# elif defined size_t
#  define YYSIZE_T size_t
# elif defined __STDC_VERSION__ && 199901 <= __STDC_VERSION__
#  include <stddef.h> /* INFRINGES ON USER NAME SPACE */
#  define YYSIZE_T size_t
# else
#  define YYSIZE_T unsigned
# endif
#endif

#define YYSIZE_MAXIMUM                                  \
  YY_CAST (YYPTRDIFF_T,                                 \
           (YYPTRDIFF_MAXIMUM < YY_CAST (YYSIZE_T, -1)  \
            ? YYPTRDIFF_MAXIMUM                         \
            : YY_CAST (YYSIZE_T, -1)))

#define YYSIZEOF(X) YY_CAST (YYPTRDIFF_T, sizeof (X))


/* Stored state numbers (used for stacks). */
typedef yytype_uint8 yy_state_t;

/* State numbers in computations.  */
typedef int yy_state_fast_t;

#ifndef YY_
# if defined YYENABLE_NLS && YYENABLE_NLS
#  if ENABLE_NLS
#   include <libintl.h> /* INFRINGES ON USER NAME SPACE */
#   define YY_(Msgid) dgettext ("bison-runtime", Msgid)
#  endif
# endif
# ifndef YY_
#  define YY_(Msgid) Msgid
# endif
#endif


#ifndef YY_ATTRIBUTE_PURE
# if defined __GNUC__ && 2 < __GNUC__ + (96 <= __GNUC_MINOR__)
#  define YY_ATTRIBUTE_PURE __attribute__ ((__pure__))
# else
#  define YY_ATTRIBUTE_PURE
# endif
#endif

#ifndef YY_ATTRIBUTE_UNUSED
# if defined __GNUC__ && 2 < __GNUC__ + (7 <= __GNUC_MINOR__)
#  define YY_ATTRIBUTE_UNUSED __attribute__ ((__unused__))
# else
#  define YY_ATTRIBUTE_UNUSED
# endif
#endif

/* Suppress unused-variable warnings by "using" E.  */
#if ! defined lint || defined __GNUC__
# define YY_USE(E) ((void) (E))
#else
# define YY_USE(E) /* empty */
#endif

/* Suppress an incorrect diagnostic about yylval being uninitialized.  */
#if defined __GNUC__ && ! defined __ICC && 406 <= __GNUC__ * 100 + __GNUC_MINOR__
# if __GNUC__ * 100 + __GNUC_MINOR__ < 407
#  define YY_IGNORE_MAYBE_UNINITIALIZED_BEGIN                           \
    _Pragma ("GCC diagnostic push")                                     \
    _Pragma ("GCC diagnostic ignored \"-Wuninitialized\"")
# else
#  define YY_IGNORE_MAYBE_UNINITIALIZED_BEGIN                           \
    _Pragma ("GCC diagnostic push")                                     \
    _Pragma ("GCC diagnostic ignored \"-Wuninitialized\"")              \
    _Pragma ("GCC diagnostic ignored \"-Wmaybe-uninitialized\"")
# endif
# define YY_IGNORE_MAYBE_UNINITIALIZED_END      \
    _Pragma ("GCC diagnostic pop")
#else
# define YY_INITIAL_VALUE(Value) Value
#endif
#ifndef YY_IGNORE_MAYBE_UNINITIALIZED_BEGIN
# define YY_IGNORE_MAYBE_UNINITIALIZED_BEGIN
# define YY_IGNORE_MAYBE_UNINITIALIZED_END
#endif
#ifndef YY_INITIAL_VALUE
# define YY_INITIAL_VALUE(Value) /* Nothing. */
#endif

#if defined __cplusplus && defined __GNUC__ && ! defined __ICC && 6 <= __GNUC__
# define YY_IGNORE_USELESS_CAST_BEGIN                          \
    _Pragma ("GCC diagnostic push")                            \
    _Pragma ("GCC diagnostic ignored \"-Wuseless-cast\"")
# define YY_IGNORE_USELESS_CAST_END            \
    _Pragma ("GCC diagnostic pop")
#endif
#ifndef YY_IGNORE_USELESS_CAST_BEGIN
# define YY_IGNORE_USELESS_CAST_BEGIN
# define YY_IGNORE_USELESS_CAST_END
#endif


#define YY_ASSERT(E) ((void) (0 && (E)))

#if !defined yyoverflow

/* The parser invokes alloca or malloc; define the necessary symbols.  */

# ifdef YYSTACK_USE_ALLOCA
#  if YYSTACK_USE_ALLOCA
#   ifdef __GNUC__
#    define YYSTACK_ALLOC __builtin_alloca
#   elif defined __BUILTIN_VA_ARG_INCR
#    include <alloca.h> /* INFRINGES ON USER NAME SPACE */
#   elif defined _AIX
#    define YYSTACK_ALLOC __alloca
#   elif defined _MSC_VER
#    include <malloc.h> /* INFRINGES ON USER NAME SPACE */
#    define alloca _alloca
#   else
#    define YYSTACK_ALLOC alloca
#    if ! defined _ALLOCA_H && ! defined EXIT_SUCCESS
#     include <stdlib.h> /* INFRINGES ON USER NAME SPACE */
      /* Use EXIT_SUCCESS as a witness for stdlib.h.  */
#     ifndef EXIT_SUCCESS
#      define EXIT_SUCCESS 0
#     endif
#    endif
#   endif
#  endif
# endif

# ifdef YYSTACK_ALLOC
   /* Pacify GCC's 'empty if-body' warning.  */
#  define YYSTACK_FREE(Ptr) do { /* empty */; } while (0)
#  ifndef YYSTACK_ALLOC_MAXIMUM
    /* The OS might guarantee only one guard page at the bottom of the stack,
       and a page size can be as small as 4096 bytes.  So we cannot safely
       invoke alloca (N) if N exceeds 4096.  Use a slightly smaller number
       to allow for a few compiler-allocated temporary stack slots.  */
#   define YYSTACK_ALLOC_MAXIMUM 4032 /* reasonable circa 2006 */
#  endif
# else
#  define YYSTACK_ALLOC YYMALLOC
#  define YYSTACK_FREE YYFREE
#  ifndef YYSTACK_ALLOC_MAXIMUM
#   define YYSTACK_ALLOC_MAXIMUM YYSIZE_MAXIMUM
#  endif
#  if (defined __cplusplus && ! defined EXIT_SUCCESS \
       && ! ((defined YYMALLOC || defined malloc) \
             && (defined YYFREE || defined free)))
#   include <stdlib.h> /* INFRINGES ON USER NAME SPACE */
#   ifndef EXIT_SUCCESS
#    define EXIT_SUCCESS 0
#   endif
#  endif
#  ifndef YYMALLOC
#   define YYMALLOC malloc
#   if ! defined malloc && ! defined EXIT_SUCCESS
void *malloc (YYSIZE_T); /* INFRINGES ON USER NAME SPACE */
#   endif
#  endif
#  ifndef YYFREE
#   define YYFREE free
#   if ! defined free && ! defined EXIT_SUCCESS
void free (void *); /* INFRINGES ON USER NAME SPACE */
#   endif
#  endif
# endif
#endif /* !defined yyoverflow */

#if (! defined yyoverflow \
     && (! defined __cplusplus \
         || (defined YYSTYPE_IS_TRIVIAL && YYSTYPE_IS_TRIVIAL)))

/* A type that is properly aligned for any stack member.  */
union yyalloc
{
  yy_state_t yyss_alloc;
  YYSTYPE yyvs_alloc;
};

/* The size of the maximum gap between one aligned stack and the next.  */
# define YYSTACK_GAP_MAXIMUM (YYSIZEOF (union yyalloc) - 1)

/* The size of an array large to enough to hold all stacks, each with
   N elements.  */
# define YYSTACK_BYTES(N) \
     ((N) * (YYSIZEOF (yy_state_t) + YYSIZEOF (YYSTYPE)) \
      + YYSTACK_GAP_MAXIMUM)

# define YYCOPY_NEEDED 1

/* Relocate STACK from its old location to the new one.  The
   local variables YYSIZE and YYSTACKSIZE give the old and new number of
   elements in the stack, and YYPTR gives the new location of the
   stack.  Advance YYPTR to a properly aligned location for the next
   stack.  */
# define YYSTACK_RELOCATE(Stack_alloc, Stack)                           \
    do                                                                  \
      {                                                                 \
        YYPTRDIFF_T yynewbytes;                                         \
        YYCOPY (&yyptr->Stack_alloc, Stack, yysize);                    \
        Stack = &yyptr->Stack_alloc;                                    \
        yynewbytes = yystacksize * YYSIZEOF (*Stack) + YYSTACK_GAP_MAXIMUM; \
        yyptr += yynewbytes / YYSIZEOF (*yyptr);                        \
      }                                                                 \
    while (0)

#endif

#if defined YYCOPY_NEEDED && YYCOPY_NEEDED
/* Copy COUNT objects from SRC to DST.  The source and destination do
   not overlap.  */
# ifndef YYCOPY
#  if defined __GNUC__ && 1 < __GNUC__
#   define YYCOPY(Dst, Src, Count) \
      __builtin_memcpy (Dst, Src, YY_CAST (YYSIZE_T, (Count)) * sizeof (*(Src)))
#  else
#   define YYCOPY(Dst, Src, Count)              \
      do                                        \
        {                                       \
          YYPTRDIFF_T yyi;                      \
          for (yyi = 0; yyi < (Count); yyi++)   \
            (Dst)[yyi] = (Src)[yyi];            \
        }                                       \
      while (0)
#  endif
# endif
#endif /* !YYCOPY_NEEDED */

/* YYFINAL -- State number of the termination state.  */
#define YYFINAL  67
/* YYLAST -- Last index in YYTABLE.  */
#define YYLAST   458

/* YYNTOKENS -- Number of terminals.  */
#define YYNTOKENS  48
/* YYNNTS -- Number of nonterminals.  */
#define YYNNTS  25
/* YYNRULES -- Number of rules.  */
#define YYNRULES  104
/* YYNSTATES -- Number of states.  */
#define YYNSTATES  182

/* YYMAXUTOK -- Last valid token kind.  */
#define YYMAXUTOK   284


/* YYTRANSLATE(TOKEN-NUM) -- Symbol number corresponding to TOKEN-NUM
   as returned by yylex, with out-of-bounds checking.  */
#define YYTRANSLATE(YYX)                                \
  (0 <= (YYX) && (YYX) <= YYMAXUTOK                     \
   ? YY_CAST (yysymbol_kind_t, yytranslate[YYX])        \
   : YYSYMBOL_YYUNDEF)

/* YYTRANSLATE[TOKEN-NUM] -- Symbol number corresponding to TOKEN-NUM
   as returned by yylex.  */
static const yytype_int8 yytranslate[] =
{
       0,     2,     2,     2,     2,     2,     2,     2,     2,     2,
      37,     2,     2,     2,     2,     2,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     2,    11,     2,     2,
      42,    43,     9,     7,    41,     8,     2,    10,     2,     2,
       2,     2,     2,     2,     2,     2,     2,     2,     2,    40,
      46,    36,    47,     2,     2,     2,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     2,     2,     2,     2,
       2,    44,     2,    45,    12,     2,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     2,     2,     2,     2,
       2,     2,     2,    38,     2,    39,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     2,     2,     2,     2,
       2,     2,     2,     2,     2,     2,     1,     2,     3,     4,
       5,     6,    13,    14,    15,    16,    17,    18,    19,    20,
      21,    22,    23,    24,    25,    26,    27,    28,    29,    30,
      31,    32,    33,    34,    35
};

#if YYDEBUG
/* YYRLINE[YYN] -- Source line where rule number YYN was defined.  */
static const yytype_int16 yyrline[] =
{
       0,   112,   112,   113,   116,   117,   120,   123,   124,   125,
     126,   129,   130,   131,   132,   133,   134,   137,   138,   139,
     140,   141,   142,   143,   144,   145,   146,   147,   148,   149,
     150,   153,   156,   159,   162,   165,   166,   169,   170,   173,
     174,   177,   178,   179,   182,   183,   186,   187,   190,   191,
     192,   193,   196,   199,   200,   201,   202,   203,   204,   205,
     208,   209,   212,   213,   216,   217,   218,   219,   220,   221,
     222,   223,   224,   225,   226,   227,   228,   229,   230,   231,
     232,   233,   234,   235,   236,   237,   238,   239,   240,   241,
     242,   243,   244,   245,   248,   249,   250,   251,   252,   253,
     254,   255,   256,   257,   260
};
#endif

/** Accessing symbol of state STATE.  */
#define YY_ACCESSING_SYMBOL(State) YY_CAST (yysymbol_kind_t, yystos[State])

#if YYDEBUG || 0
/* The user-facing name of the symbol whose (internal) number is
   YYSYMBOL.  No bounds checking.  */
static const char *yysymbol_name (yysymbol_kind_t yysymbol) YY_ATTRIBUTE_UNUSED;

/* YYTNAME[SYMBOL-NUM] -- String name of the symbol SYMBOL-NUM.
   First, the terminals, then, starting at YYNTOKENS, nonterminals.  */
static const char *const yytname[] =
{
  "\"end of file\"", "error", "\"invalid token\"", "ID", "STRING",
  "NUMBER", "EQOP", "'+'", "'-'", "'*'", "'/'", "'%'", "'^'", "INCDEC",
  "HOME", "LOOP", "DOT", "EQ", "LE", "GE", "NE", "DEF", "BREAK", "QUIT",
  "LENGTH", "RETURN", "FOR", "IF", "WHILE", "SQRT", "SCALE", "IBASE",
  "OBASE", "AUTO", "PARAM", "PRINT", "'='", "'\\n'", "'{'", "'}'", "';'",
  "','", "'('", "')'", "'['", "']'", "'<'", "'>'", "$accept", "program",
  "item", "function", "scolonlst", "statlst", "stat", "while", "if", "for",
  "def", "parlst", "params", "param", "autolst", "locals", "local",
  "arglst", "cond", "rel", "exprstat", "expr", "nexpr", "assign", "ary", YY_NULLPTR
};

static const char *
yysymbol_name (yysymbol_kind_t yysymbol)
{
  return yytname[yysymbol];
}
#endif

#define YYPACT_NINF (-128)

#define yypact_value_is_default(Yyn) \
  ((Yyn) == YYPACT_NINF)

#define YYTABLE_NINF (-62)

#define yytable_value_is_error(Yyn) \
  0

/* YYPACT[STATE-NUM] -- Index in YYTABLE of the portion describing
   STATE-NUM.  */
static const yytype_int16 yypact[] =
{
     180,    69,  -128,  -128,   314,   113,  -128,    23,  -128,  -128,
     -20,   -12,  -128,  -128,  -128,    -3,    15,     6,    19,   310,
     274,   314,    40,   180,  -128,   -22,  -128,     1,     1,     8,
      11,  -128,   162,    58,   121,   314,  -128,   314,   211,   314,
      88,    25,  -128,  -128,     2,  -128,  -128,  -128,  -128,   314,
     220,   314,   314,  -128,   314,   314,   314,  -128,   314,   314,
    -128,   314,    17,   162,   126,  -128,   264,  -128,  -128,  -128,
     274,   314,   274,   274,   314,    -2,    14,   314,   314,   314,
     314,   314,   314,   162,   162,    90,  -128,    20,   408,    -1,
     314,  -128,   314,  -128,   355,  -128,   371,   381,   162,   162,
     392,   162,   162,   162,   162,   314,   274,  -128,   274,  -128,
    -128,    24,   248,  -128,  -128,   418,    12,  -128,   -38,  -128,
      41,    25,    25,    42,    42,    42,    42,   117,  -128,   345,
    -128,   162,   162,  -128,  -128,  -128,  -128,   162,  -128,  -128,
    -128,   314,   314,   314,   314,   314,   314,   314,    34,    77,
    -128,    60,    63,  -128,   162,   162,   162,   162,   162,   162,
      59,  -128,  -128,   104,   274,   345,   314,    65,   -24,  -128,
     150,  -128,   398,    72,  -128,  -128,   104,  -128,   274,  -128,
    -128,  -128
};

/* YYDEFACT[STATE-NUM] -- Default reduction number in state STATE-NUM.
   Performed when YYTABLE does not specify something else to do.  Zero
   means the default is an error.  */
static const yytype_int8 yydefact[] =
{
       7,    65,    21,    64,     0,     0,    66,     0,    22,    23,
       0,    24,    33,    32,    31,     0,    67,    68,    69,     0,
      11,     0,     0,     7,     5,     0,     8,     0,     0,     0,
       0,    17,     0,    62,    63,     0,    89,     0,     0,     0,
      70,    74,    62,    63,    84,    85,    86,    87,    34,     0,
       0,     0,     0,    90,     0,     0,     0,    91,     0,     0,
      92,     0,    19,    18,     0,    12,     0,     1,     3,     4,
      10,     0,     0,     0,     0,     0,     0,     0,     0,     0,
       0,     0,     0,    99,    94,    65,    73,     0,    48,     0,
       0,    93,     0,    88,     0,    26,     0,     0,   100,    95,
       0,   101,    96,   102,    97,     0,    15,    29,    16,    71,
       9,     0,    53,    27,    28,     0,    39,    35,     0,    37,
       0,    75,    76,    77,    78,    79,    80,     0,    72,     0,
     104,   103,    98,    81,    25,    82,    83,    20,    13,    14,
      52,     0,     0,     0,     0,     0,     0,     0,     0,     0,
      36,    41,    49,    50,    54,    55,    56,    57,    58,    59,
       0,    40,    38,     0,    11,     0,     0,    46,     0,    44,
       0,    51,     0,     0,    42,    43,     0,     6,     0,    47,
      45,    30
};

/* YYPGOTO[NTERM-NUM].  */
static const yytype_int16 yypgoto[] =
{
    -128,    91,  -128,  -128,  -128,   -46,    13,  -128,  -128,  -128,
    -128,  -128,  -128,   -26,  -128,  -128,   -49,  -127,   100,   -18,
    -128,    10,     0,     4,    87
};

/* YYDEFGOTO[NTERM-NUM].  */
static const yytype_uint8 yydefgoto[] =
{
       0,    22,    23,    24,    25,    64,    26,    27,    28,    29,
      30,    76,   118,   119,   164,   168,   169,    87,    72,   111,
      31,    32,    42,    43,    40
};

/* YYTABLE[YYPACT[STATE-NUM]] -- What to do in state STATE-NUM.  If
   positive, shift that token.  If negative, reduce the rule whose
   number is the opposite.  If YYTABLE_NINF, syntax error.  */
static const yytype_int16 yytable[] =
{
      33,   116,   153,   149,    34,   150,    77,    78,    79,    80,
      81,    82,    56,   174,    41,    69,   175,   176,    70,    57,
      33,    52,    49,    33,    34,    59,    48,    34,    53,    63,
      50,    66,    60,    65,    79,    80,    81,    82,   171,    51,
      67,   117,    58,    71,   130,    83,    39,    84,    88,    89,
      74,    54,   120,    75,    82,    61,   148,    55,   105,    94,
      96,    97,    98,   128,    99,   100,   101,   140,   102,   103,
      33,   104,    33,    33,    34,    35,    34,    34,   151,   161,
     116,   112,    36,   110,   115,   113,   114,   121,   122,   123,
     124,   125,   126,   163,    90,   -60,    35,   -60,   -60,   166,
     131,    91,   132,    36,   165,    37,    33,   167,    33,   173,
      34,    38,    34,    39,    68,   137,    44,   179,   170,   138,
       1,   139,     3,   162,    92,     4,    37,   180,    73,   160,
       5,    93,    38,     6,   127,     0,     0,    89,     0,    88,
       0,    10,     0,    45,    46,    47,    15,    16,    17,    18,
       0,   154,   155,   156,   157,   158,   159,   112,   -61,    21,
     -61,   -61,   152,   106,    33,   107,   108,     0,    34,    77,
      78,    79,    80,    81,    82,    88,   172,    65,    33,     0,
      -2,     0,    34,     1,     2,     3,     0,   106,     4,   177,
     108,   181,     0,     5,     0,     0,     6,     0,     0,     0,
       0,     7,     8,     9,    10,    11,    12,    13,    14,    15,
      16,    17,    18,     0,    85,    19,     3,     0,    20,     4,
       0,     0,    21,     1,     5,     3,     0,     6,     4,     0,
       0,     0,     0,     5,     0,    10,     6,     0,     0,     0,
      15,    16,    17,    18,    10,     0,     0,     0,     0,    15,
      16,    17,    18,    21,    86,    77,    78,    79,    80,    81,
      82,     0,    21,    95,     0,   141,   142,   143,   144,     0,
       0,    77,    78,    79,    80,    81,    82,     1,     2,     3,
       0,     0,     4,     0,     0,     0,     0,     5,     0,     0,
       6,     0,     0,     0,   145,   146,     8,     9,    10,    11,
      12,    13,    14,    15,    16,    17,    18,   109,     0,    19,
       0,     0,    20,     1,    62,     3,    21,     1,     4,     3,
       0,     0,     4,     5,     0,     0,     6,     5,     0,     0,
       6,     0,     0,     0,    10,     0,     0,     0,    10,    15,
      16,    17,    18,    15,    16,    17,    18,     0,    85,     0,
       3,     0,    21,     4,     0,     0,    21,     0,     5,     0,
       0,     6,    77,    78,    79,    80,    81,    82,     0,    10,
       0,     0,     0,     0,    15,    16,    17,    18,    77,    78,
      79,    80,    81,    82,     0,     0,     0,    21,    77,    78,
      79,    80,    81,    82,     0,     0,     0,     0,   133,    77,
      78,    79,    80,    81,    82,    77,    78,    79,    80,    81,
      82,     0,     0,     0,   134,    77,    78,    79,    80,    81,
      82,     0,     0,     0,   135,    77,    78,    79,    80,    81,
      82,     0,     0,     0,     0,   136,     0,     0,     0,     0,
       0,   178,     0,     0,     0,     0,     0,     0,     0,   129,
       0,     0,     0,     0,     0,     0,     0,     0,   147
};

static const yytype_int16 yycheck[] =
{
       0,     3,   129,    41,     0,    43,     7,     8,     9,    10,
      11,    12,     6,    37,     4,    37,    40,    41,    40,    13,
      20,     6,    42,    23,    20,     6,     3,    23,    13,    19,
      42,    21,    13,    20,     9,    10,    11,    12,   165,    42,
       0,    43,    36,    42,    45,    35,    44,    37,    38,    39,
      42,    36,    38,    42,    12,    36,    44,    42,    41,    49,
      50,    51,    52,    43,    54,    55,    56,    43,    58,    59,
      70,    61,    72,    73,    70,     6,    72,    73,    37,    45,
       3,    71,    13,    70,    74,    72,    73,    77,    78,    79,
      80,    81,    82,    33,     6,    37,     6,    39,    40,    40,
      90,    13,    92,    13,    41,    36,   106,     3,   108,    44,
     106,    42,   108,    44,    23,   105,     3,    45,   164,   106,
       3,   108,     5,   149,    36,     8,    36,   176,    28,   147,
      13,    44,    42,    16,    44,    -1,    -1,   127,    -1,   129,
      -1,    24,    -1,    30,    31,    32,    29,    30,    31,    32,
      -1,   141,   142,   143,   144,   145,   146,   147,    37,    42,
      39,    40,    45,    37,   164,    39,    40,    -1,   164,     7,
       8,     9,    10,    11,    12,   165,   166,   164,   178,    -1,
       0,    -1,   178,     3,     4,     5,    -1,    37,     8,    39,
      40,   178,    -1,    13,    -1,    -1,    16,    -1,    -1,    -1,
      -1,    21,    22,    23,    24,    25,    26,    27,    28,    29,
      30,    31,    32,    -1,     3,    35,     5,    -1,    38,     8,
      -1,    -1,    42,     3,    13,     5,    -1,    16,     8,    -1,
      -1,    -1,    -1,    13,    -1,    24,    16,    -1,    -1,    -1,
      29,    30,    31,    32,    24,    -1,    -1,    -1,    -1,    29,
      30,    31,    32,    42,    43,     7,     8,     9,    10,    11,
      12,    -1,    42,    43,    -1,    17,    18,    19,    20,    -1,
      -1,     7,     8,     9,    10,    11,    12,     3,     4,     5,
      -1,    -1,     8,    -1,    -1,    -1,    -1,    13,    -1,    -1,
      16,    -1,    -1,    -1,    46,    47,    22,    23,    24,    25,
      26,    27,    28,    29,    30,    31,    32,    43,    -1,    35,
      -1,    -1,    38,     3,     4,     5,    42,     3,     8,     5,
      -1,    -1,     8,    13,    -1,    -1,    16,    13,    -1,    -1,
      16,    -1,    -1,    -1,    24,    -1,    -1,    -1,    24,    29,
      30,    31,    32,    29,    30,    31,    32,    -1,     3,    -1,
       5,    -1,    42,     8,    -1,    -1,    42,    -1,    13,    -1,
      -1,    16,     7,     8,     9,    10,    11,    12,    -1,    24,
      -1,    -1,    -1,    -1,    29,    30,    31,    32,     7,     8,
       9,    10,    11,    12,    -1,    -1,    -1,    42,     7,     8,
       9,    10,    11,    12,    -1,    -1,    -1,    -1,    43,     7,
       8,     9,    10,    11,    12,     7,     8,     9,    10,    11,
      12,    -1,    -1,    -1,    43,     7,     8,     9,    10,    11,
      12,    -1,    -1,    -1,    43,     7,     8,     9,    10,    11,
      12,    -1,    -1,    -1,    -1,    43,    -1,    -1,    -1,    -1,
      -1,    43,    -1,    -1,    -1,    -1,    -1,    -1,    -1,    41,
      -1,    -1,    -1,    -1,    -1,    -1,    -1,    -1,    40
};

/* YYSTOS[STATE-NUM] -- The symbol kind of the accessing symbol of
   state STATE-NUM.  */
static const yytype_int8 yystos[] =
{
       0,     3,     4,     5,     8,    13,    16,    21,    22,    23,
      24,    25,    26,    27,    28,    29,    30,    31,    32,    35,
      38,    42,    49,    50,    51,    52,    54,    55,    56,    57,
      58,    68,    69,    70,    71,     6,    13,    36,    42,    44,
      72,    69,    70,    71,     3,    30,    31,    32,     3,    42,
      42,    42,     6,    13,    36,    42,     6,    13,    36,     6,
      13,    36,     4,    69,    53,    54,    69,     0,    49,    37,
      40,    42,    66,    66,    42,    42,    59,     7,     8,     9,
      10,    11,    12,    69,    69,     3,    43,    65,    69,    69,
       6,    13,    36,    72,    69,    43,    69,    69,    69,    69,
      69,    69,    69,    69,    69,    41,    37,    39,    40,    43,
      54,    67,    69,    54,    54,    69,     3,    43,    60,    61,
      38,    69,    69,    69,    69,    69,    69,    44,    43,    41,
      45,    69,    69,    43,    43,    43,    43,    69,    54,    54,
      43,    17,    18,    19,    20,    46,    47,    40,    44,    41,
      43,    37,    45,    65,    69,    69,    69,    69,    69,    69,
      67,    45,    61,    33,    62,    41,    40,     3,    63,    64,
      53,    65,    69,    44,    37,    40,    41,    39,    43,    45,
      64,    54
};

/* YYR1[RULE-NUM] -- Symbol kind of the left-hand side of rule RULE-NUM.  */
static const yytype_int8 yyr1[] =
{
       0,    48,    49,    49,    50,    50,    51,    52,    52,    52,
      52,    53,    53,    53,    53,    53,    53,    54,    54,    54,
      54,    54,    54,    54,    54,    54,    54,    54,    54,    54,
      54,    55,    56,    57,    58,    59,    59,    60,    60,    61,
      61,    62,    62,    62,    63,    63,    64,    64,    65,    65,
      65,    65,    66,    67,    67,    67,    67,    67,    67,    67,
      68,    68,    69,    69,    70,    70,    70,    70,    70,    70,
      70,    70,    70,    70,    70,    70,    70,    70,    70,    70,
      70,    70,    70,    70,    70,    70,    70,    70,    70,    70,
      70,    70,    70,    70,    71,    71,    71,    71,    71,    71,
      71,    71,    71,    71,    72
};

/* YYR2[RULE-NUM] -- Number of symbols on the right-hand side of rule RULE-NUM.  */
static const yytype_int8 yyr2[] =
{
       0,     2,     0,     2,     2,     1,     7,     0,     1,     3,
       2,     0,     1,     3,     3,     2,     2,     1,     2,     2,
       4,     1,     1,     1,     1,     4,     3,     3,     3,     3,
       9,     1,     1,     1,     2,     2,     3,     1,     3,     1,
       3,     0,     3,     3,     1,     3,     1,     3,     1,     3,
       3,     5,     3,     1,     3,     3,     3,     3,     3,     3,
       1,     1,     1,     1,     1,     1,     1,     1,     1,     1,
       2,     3,     4,     3,     2,     3,     3,     3,     3,     3,
       3,     4,     4,     4,     2,     2,     2,     2,     3,     2,
       2,     2,     2,     3,     3,     3,     3,     3,     4,     3,
       3,     3,     3,     4,     3
};


enum { YYENOMEM = -2 };

#define yyerrok         (yyerrstatus = 0)
#define yyclearin       (yychar = YYEMPTY)

#define YYACCEPT        goto yyacceptlab
#define YYABORT         goto yyabortlab
#define YYERROR         goto yyerrorlab
#define YYNOMEM         goto yyexhaustedlab


#define YYRECOVERING()  (!!yyerrstatus)

#define YYBACKUP(Token, Value)                                    \
  do                                                              \
    if (yychar == YYEMPTY)                                        \
      {                                                           \
        yychar = (Token);                                         \
        yylval = (Value);                                         \
        YYPOPSTACK (yylen);                                       \
        yystate = *yyssp;                                         \
        goto yybackup;                                            \
      }                                                           \
    else                                                          \
      {                                                           \
        yyerror (YY_("syntax error: cannot back up")); \
        YYERROR;                                                  \
      }                                                           \
  while (0)

/* Backward compatibility with an undocumented macro.
   Use YYerror or YYUNDEF. */
#define YYERRCODE YYUNDEF


/* Enable debugging if requested.  */
#if YYDEBUG

# ifndef YYFPRINTF
#  include <stdio.h> /* INFRINGES ON USER NAME SPACE */
#  define YYFPRINTF fprintf
# endif

# define YYDPRINTF(Args)                        \
do {                                            \
  if (yydebug)                                  \
    YYFPRINTF Args;                             \
} while (0)




# define YY_SYMBOL_PRINT(Title, Kind, Value, Location)                    \
do {                                                                      \
  if (yydebug)                                                            \
    {                                                                     \
      YYFPRINTF (stderr, "%s ", Title);                                   \
      yy_symbol_print (stderr,                                            \
                  Kind, Value); \
      YYFPRINTF (stderr, "\n");                                           \
    }                                                                     \
} while (0)


/*-----------------------------------.
| Print this symbol's value on YYO.  |
`-----------------------------------*/

static void
yy_symbol_value_print (FILE *yyo,
                       yysymbol_kind_t yykind, YYSTYPE const * const yyvaluep)
{
  FILE *yyoutput = yyo;
  YY_USE (yyoutput);
  if (!yyvaluep)
    return;
  YY_IGNORE_MAYBE_UNINITIALIZED_BEGIN
  YY_USE (yykind);
  YY_IGNORE_MAYBE_UNINITIALIZED_END
}


/*---------------------------.
| Print this symbol on YYO.  |
`---------------------------*/

static void
yy_symbol_print (FILE *yyo,
                 yysymbol_kind_t yykind, YYSTYPE const * const yyvaluep)
{
  YYFPRINTF (yyo, "%s %s (",
             yykind < YYNTOKENS ? "token" : "nterm", yysymbol_name (yykind));

  yy_symbol_value_print (yyo, yykind, yyvaluep);
  YYFPRINTF (yyo, ")");
}

/*------------------------------------------------------------------.
| yy_stack_print -- Print the state stack from its BOTTOM up to its |
| TOP (included).                                                   |
`------------------------------------------------------------------*/

static void
yy_stack_print (yy_state_t *yybottom, yy_state_t *yytop)
{
  YYFPRINTF (stderr, "Stack now");
  for (; yybottom <= yytop; yybottom++)
    {
      int yybot = *yybottom;
      YYFPRINTF (stderr, " %d", yybot);
    }
  YYFPRINTF (stderr, "\n");
}

# define YY_STACK_PRINT(Bottom, Top)                            \
do {                                                            \
  if (yydebug)                                                  \
    yy_stack_print ((Bottom), (Top));                           \
} while (0)


/*------------------------------------------------.
| Report that the YYRULE is going to be reduced.  |
`------------------------------------------------*/

static void
yy_reduce_print (yy_state_t *yyssp, YYSTYPE *yyvsp,
                 int yyrule)
{
  int yylno = yyrline[yyrule];
  int yynrhs = yyr2[yyrule];
  int yyi;
  YYFPRINTF (stderr, "Reducing stack by rule %d (line %d):\n",
             yyrule - 1, yylno);
  /* The symbols being reduced.  */
  for (yyi = 0; yyi < yynrhs; yyi++)
    {
      YYFPRINTF (stderr, "   $%d = ", yyi + 1);
      yy_symbol_print (stderr,
                       YY_ACCESSING_SYMBOL (+yyssp[yyi + 1 - yynrhs]),
                       &yyvsp[(yyi + 1) - (yynrhs)]);
      YYFPRINTF (stderr, "\n");
    }
}

# define YY_REDUCE_PRINT(Rule)          \
do {                                    \
  if (yydebug)                          \
    yy_reduce_print (yyssp, yyvsp, Rule); \
} while (0)

/* Nonzero means print parse trace.  It is left uninitialized so that
   multiple parsers can coexist.  */
int yydebug;
#else /* !YYDEBUG */
# define YYDPRINTF(Args) ((void) 0)
# define YY_SYMBOL_PRINT(Title, Kind, Value, Location)
# define YY_STACK_PRINT(Bottom, Top)
# define YY_REDUCE_PRINT(Rule)
#endif /* !YYDEBUG */


/* YYINITDEPTH -- initial size of the parser's stacks.  */
#ifndef YYINITDEPTH
# define YYINITDEPTH 200
#endif

/* YYMAXDEPTH -- maximum size the stacks can grow to (effective only
   if the built-in stack extension method is used).

   Do not make this value too large; the results are undefined if
   YYSTACK_ALLOC_MAXIMUM < YYSTACK_BYTES (YYMAXDEPTH)
   evaluated with infinite-precision integer arithmetic.  */

#ifndef YYMAXDEPTH
# define YYMAXDEPTH 10000
#endif






/*-----------------------------------------------.
| Release the memory associated to this symbol.  |
`-----------------------------------------------*/

static void
yydestruct (const char *yymsg,
            yysymbol_kind_t yykind, YYSTYPE *yyvaluep)
{
  YY_USE (yyvaluep);
  if (!yymsg)
    yymsg = "Deleting";
  YY_SYMBOL_PRINT (yymsg, yykind, yyvaluep, yylocationp);

  YY_IGNORE_MAYBE_UNINITIALIZED_BEGIN
  YY_USE (yykind);
  YY_IGNORE_MAYBE_UNINITIALIZED_END
}


/* Lookahead token kind.  */
int yychar;

/* The semantic value of the lookahead symbol.  */
YYSTYPE yylval;
/* Number of syntax errors so far.  */
int yynerrs;




/*----------.
| yyparse.  |
`----------*/

int
yyparse (void)
{
    yy_state_fast_t yystate = 0;
    /* Number of tokens to shift before error messages enabled.  */
    int yyerrstatus = 0;

    /* Refer to the stacks through separate pointers, to allow yyoverflow
       to reallocate them elsewhere.  */

    /* Their size.  */
    YYPTRDIFF_T yystacksize = YYINITDEPTH;

    /* The state stack: array, bottom, top.  */
    yy_state_t yyssa[YYINITDEPTH];
    yy_state_t *yyss = yyssa;
    yy_state_t *yyssp = yyss;

    /* The semantic value stack: array, bottom, top.  */
    YYSTYPE yyvsa[YYINITDEPTH];
    YYSTYPE *yyvs = yyvsa;
    YYSTYPE *yyvsp = yyvs;

  int yyn;
  /* The return value of yyparse.  */
  int yyresult;
  /* Lookahead symbol kind.  */
  yysymbol_kind_t yytoken = YYSYMBOL_YYEMPTY;
  /* The variables used to return semantic value and location from the
     action routines.  */
  YYSTYPE yyval;



#define YYPOPSTACK(N)   (yyvsp -= (N), yyssp -= (N))

  /* The number of symbols on the RHS of the reduced rule.
     Keep to zero when no symbol should be popped.  */
  int yylen = 0;

  YYDPRINTF ((stderr, "Starting parse\n"));

  yychar = YYEMPTY; /* Cause a token to be read.  */

  goto yysetstate;


/*------------------------------------------------------------.
| yynewstate -- push a new state, which is found in yystate.  |
`------------------------------------------------------------*/
yynewstate:
  /* In all cases, when you get here, the value and location stacks
     have just been pushed.  So pushing a state here evens the stacks.  */
  yyssp++;


/*--------------------------------------------------------------------.
| yysetstate -- set current state (the top of the stack) to yystate.  |
`--------------------------------------------------------------------*/
yysetstate:
  YYDPRINTF ((stderr, "Entering state %d\n", yystate));
  YY_ASSERT (0 <= yystate && yystate < YYNSTATES);
  YY_IGNORE_USELESS_CAST_BEGIN
  *yyssp = YY_CAST (yy_state_t, yystate);
  YY_IGNORE_USELESS_CAST_END
  YY_STACK_PRINT (yyss, yyssp);

  if (yyss + yystacksize - 1 <= yyssp)
#if !defined yyoverflow && !defined YYSTACK_RELOCATE
    YYNOMEM;
#else
    {
      /* Get the current used size of the three stacks, in elements.  */
      YYPTRDIFF_T yysize = yyssp - yyss + 1;

# if defined yyoverflow
      {
        /* Give user a chance to reallocate the stack.  Use copies of
           these so that the &'s don't force the real ones into
           memory.  */
        yy_state_t *yyss1 = yyss;
        YYSTYPE *yyvs1 = yyvs;

        /* Each stack pointer address is followed by the size of the
           data in use in that stack, in bytes.  This used to be a
           conditional around just the two extra args, but that might
           be undefined if yyoverflow is a macro.  */
        yyoverflow (YY_("memory exhausted"),
                    &yyss1, yysize * YYSIZEOF (*yyssp),
                    &yyvs1, yysize * YYSIZEOF (*yyvsp),
                    &yystacksize);
        yyss = yyss1;
        yyvs = yyvs1;
      }
# else /* defined YYSTACK_RELOCATE */
      /* Extend the stack our own way.  */
      if (YYMAXDEPTH <= yystacksize)
        YYNOMEM;
      yystacksize *= 2;
      if (YYMAXDEPTH < yystacksize)
        yystacksize = YYMAXDEPTH;

      {
        yy_state_t *yyss1 = yyss;
        union yyalloc *yyptr =
          YY_CAST (union yyalloc *,
                   YYSTACK_ALLOC (YY_CAST (YYSIZE_T, YYSTACK_BYTES (yystacksize))));
        if (! yyptr)
          YYNOMEM;
        YYSTACK_RELOCATE (yyss_alloc, yyss);
        YYSTACK_RELOCATE (yyvs_alloc, yyvs);
#  undef YYSTACK_RELOCATE
        if (yyss1 != yyssa)
          YYSTACK_FREE (yyss1);
      }
# endif

      yyssp = yyss + yysize - 1;
      yyvsp = yyvs + yysize - 1;

      YY_IGNORE_USELESS_CAST_BEGIN
      YYDPRINTF ((stderr, "Stack size increased to %ld\n",
                  YY_CAST (long, yystacksize)));
      YY_IGNORE_USELESS_CAST_END

      if (yyss + yystacksize - 1 <= yyssp)
        YYABORT;
    }
#endif /* !defined yyoverflow && !defined YYSTACK_RELOCATE */


  if (yystate == YYFINAL)
    YYACCEPT;

  goto yybackup;


/*-----------.
| yybackup.  |
`-----------*/
yybackup:
  /* Do appropriate processing given the current state.  Read a
     lookahead token if we need one and don't already have one.  */

  /* First try to decide what to do without reference to lookahead token.  */
  yyn = yypact[yystate];
  if (yypact_value_is_default (yyn))
    goto yydefault;

  /* Not known => get a lookahead token if don't already have one.  */

  /* YYCHAR is either empty, or end-of-input, or a valid lookahead.  */
  if (yychar == YYEMPTY)
    {
      YYDPRINTF ((stderr, "Reading a token\n"));
      yychar = yylex ();
    }

  if (yychar <= YYEOF)
    {
      yychar = YYEOF;
      yytoken = YYSYMBOL_YYEOF;
      YYDPRINTF ((stderr, "Now at end of input.\n"));
    }
  else if (yychar == YYerror)
    {
      /* The scanner already issued an error message, process directly
         to error recovery.  But do not keep the error token as
         lookahead, it is too special and may lead us to an endless
         loop in error recovery. */
      yychar = YYUNDEF;
      yytoken = YYSYMBOL_YYerror;
      goto yyerrlab1;
    }
  else
    {
      yytoken = YYTRANSLATE (yychar);
      YY_SYMBOL_PRINT ("Next token is", yytoken, &yylval, &yylloc);
    }

  /* If the proper action on seeing token YYTOKEN is to reduce or to
     detect an error, take that action.  */
  yyn += yytoken;
  if (yyn < 0 || YYLAST < yyn || yycheck[yyn] != yytoken)
    goto yydefault;
  yyn = yytable[yyn];
  if (yyn <= 0)
    {
      if (yytable_value_is_error (yyn))
        goto yyerrlab;
      yyn = -yyn;
      goto yyreduce;
    }

  /* Count tokens shifted since error; after three, turn off error
     status.  */
  if (yyerrstatus)
    yyerrstatus--;

  /* Shift the lookahead token.  */
  YY_SYMBOL_PRINT ("Shifting", yytoken, &yylval, &yylloc);
  yystate = yyn;
  YY_IGNORE_MAYBE_UNINITIALIZED_BEGIN
  *++yyvsp = yylval;
  YY_IGNORE_MAYBE_UNINITIALIZED_END

  /* Discard the shifted token.  */
  yychar = YYEMPTY;
  goto yynewstate;


/*-----------------------------------------------------------.
| yydefault -- do the default action for the current state.  |
`-----------------------------------------------------------*/
yydefault:
  yyn = yydefact[yystate];
  if (yyn == 0)
    goto yyerrlab;
  goto yyreduce;


/*-----------------------------.
| yyreduce -- do a reduction.  |
`-----------------------------*/
yyreduce:
  /* yyn is the number of a rule to reduce with.  */
  yylen = yyr2[yyn];

  /* If YYLEN is nonzero, implement the default value of the action:
     '$$ = $1'.

     Otherwise, the following line sets YYVAL to garbage.
     This behavior is undocumented and Bison
     users should not rely upon it.  Assigning to YYVAL
     unconditionally makes the parser a bit smaller, and it avoids a
     GCC warning that YYVAL may be used uninitialized.  */
  yyval = yyvsp[1-yylen];


  YY_REDUCE_PRINT (yyn);
  switch (yyn)
    {
  case 4: /* item: scolonlst '\n'  */
#line 116 "bc.y"
                                {writeout((yyvsp[-1].str));}
#line 1476 "bc.c"
    break;

  case 5: /* item: function  */
#line 117 "bc.y"
                                {writeout((yyvsp[0].str));}
#line 1482 "bc.c"
    break;

  case 6: /* function: def parlst '{' '\n' autolst statlst '}'  */
#line 120 "bc.y"
                                                   {(yyval.str) = funcode((yyvsp[-6].macro), (yyvsp[-5].str), (yyvsp[-2].str), (yyvsp[-1].str));}
#line 1488 "bc.c"
    break;

  case 7: /* scolonlst: %empty  */
#line 123 "bc.y"
                                {(yyval.str) = code("");}
#line 1494 "bc.c"
    break;

  case 9: /* scolonlst: scolonlst ';' stat  */
#line 125 "bc.y"
                                {(yyval.str) = code("%s%s", (yyvsp[-2].str), (yyvsp[0].str));}
#line 1500 "bc.c"
    break;

  case 11: /* statlst: %empty  */
#line 129 "bc.y"
                                {(yyval.str) = code("");}
#line 1506 "bc.c"
    break;

  case 13: /* statlst: statlst '\n' stat  */
#line 131 "bc.y"
                                {(yyval.str) = code("%s%s", (yyvsp[-2].str), (yyvsp[0].str));}
#line 1512 "bc.c"
    break;

  case 14: /* statlst: statlst ';' stat  */
#line 132 "bc.y"
                                {(yyval.str) = code("%s%s", (yyvsp[-2].str), (yyvsp[0].str));}
#line 1518 "bc.c"
    break;

  case 18: /* stat: PRINT expr  */
#line 138 "bc.y"
                                {(yyval.str) = code("%sps.", (yyvsp[0].str));}
#line 1524 "bc.c"
    break;

  case 19: /* stat: PRINT STRING  */
#line 139 "bc.y"
                                {(yyval.str) = code("[%s]P", (yyvsp[0].str));}
#line 1530 "bc.c"
    break;

  case 20: /* stat: PRINT STRING ',' expr  */
#line 140 "bc.y"
                                {(yyval.str) = code("[%s]P%sps.", (yyvsp[-2].str), (yyvsp[0].str));}
#line 1536 "bc.c"
    break;

  case 21: /* stat: STRING  */
#line 141 "bc.y"
                                {(yyval.str) = code("[%s]P", (yyvsp[0].str));}
#line 1542 "bc.c"
    break;

  case 22: /* stat: BREAK  */
#line 142 "bc.y"
                                {(yyval.str) = brkcode();}
#line 1548 "bc.c"
    break;

  case 23: /* stat: QUIT  */
#line 143 "bc.y"
                                {quit();}
#line 1554 "bc.c"
    break;

  case 24: /* stat: RETURN  */
#line 144 "bc.y"
                                {(yyval.str) = retcode(code(" 0"));}
#line 1560 "bc.c"
    break;

  case 25: /* stat: RETURN '(' expr ')'  */
#line 145 "bc.y"
                                {(yyval.str) = retcode((yyvsp[-1].str));}
#line 1566 "bc.c"
    break;

  case 26: /* stat: RETURN '(' ')'  */
#line 146 "bc.y"
                                {(yyval.str) = retcode(code(" 0"));}
#line 1572 "bc.c"
    break;

  case 27: /* stat: while cond stat  */
#line 147 "bc.y"
                                {(yyval.str) = whilecode((yyvsp[-2].macro), (yyvsp[-1].str), (yyvsp[0].str));}
#line 1578 "bc.c"
    break;

  case 28: /* stat: if cond stat  */
#line 148 "bc.y"
                                {(yyval.str) = ifcode((yyvsp[-2].macro), (yyvsp[-1].str), (yyvsp[0].str));}
#line 1584 "bc.c"
    break;

  case 29: /* stat: '{' statlst '}'  */
#line 149 "bc.y"
                                {(yyval.str) = (yyvsp[-1].str);}
#line 1590 "bc.c"
    break;

  case 30: /* stat: for '(' expr ';' rel ';' expr ')' stat  */
#line 150 "bc.y"
                                                  {(yyval.str) = forcode((yyvsp[-8].macro), (yyvsp[-6].str), (yyvsp[-4].str), (yyvsp[-2].str), (yyvsp[0].str));}
#line 1596 "bc.c"
    break;

  case 31: /* while: WHILE  */
#line 153 "bc.y"
                                {(yyval.macro) = macro(LOOP);}
#line 1602 "bc.c"
    break;

  case 32: /* if: IF  */
#line 156 "bc.y"
                                {(yyval.macro) = macro(IF);}
#line 1608 "bc.c"
    break;

  case 33: /* for: FOR  */
#line 159 "bc.y"
                                {(yyval.macro) = macro(LOOP);}
#line 1614 "bc.c"
    break;

  case 34: /* def: DEF ID  */
#line 162 "bc.y"
                                {(yyval.macro) = macro(DEF);}
#line 1620 "bc.c"
    break;

  case 35: /* parlst: '(' ')'  */
#line 165 "bc.y"
                                {(yyval.str) = code("");}
#line 1626 "bc.c"
    break;

  case 36: /* parlst: '(' params ')'  */
#line 166 "bc.y"
                                {(yyval.str) = (yyvsp[-1].str);}
#line 1632 "bc.c"
    break;

  case 37: /* params: param  */
#line 169 "bc.y"
                                {(yyval.str) = param(NULL, (yyvsp[0].str));}
#line 1638 "bc.c"
    break;

  case 38: /* params: params ',' param  */
#line 170 "bc.y"
                                {(yyval.str) = param((yyvsp[-2].str), (yyvsp[0].str));}
#line 1644 "bc.c"
    break;

  case 39: /* param: ID  */
#line 173 "bc.y"
                                {(yyval.str) = var((yyvsp[0].id));}
#line 1650 "bc.c"
    break;

  case 40: /* param: ID '[' ']'  */
#line 174 "bc.y"
                                {(yyval.str) = ary((yyvsp[-2].id));}
#line 1656 "bc.c"
    break;

  case 41: /* autolst: %empty  */
#line 177 "bc.y"
                                {(yyval.str) = code("");}
#line 1662 "bc.c"
    break;

  case 42: /* autolst: AUTO locals '\n'  */
#line 178 "bc.y"
                                {(yyval.str) = (yyvsp[-1].str);}
#line 1668 "bc.c"
    break;

  case 43: /* autolst: AUTO locals ';'  */
#line 179 "bc.y"
                                {(yyval.str) = (yyvsp[-1].str);}
#line 1674 "bc.c"
    break;

  case 44: /* locals: local  */
#line 182 "bc.y"
                                {(yyval.str) = local(NULL, (yyvsp[0].str));}
#line 1680 "bc.c"
    break;

  case 45: /* locals: locals ',' local  */
#line 183 "bc.y"
                                {(yyval.str) = local((yyvsp[-2].str), (yyvsp[0].str));}
#line 1686 "bc.c"
    break;

  case 46: /* local: ID  */
#line 186 "bc.y"
                                {(yyval.str) = var((yyvsp[0].id));}
#line 1692 "bc.c"
    break;

  case 47: /* local: ID '[' ']'  */
#line 187 "bc.y"
                                {(yyval.str) = ary((yyvsp[-2].id));}
#line 1698 "bc.c"
    break;

  case 49: /* arglst: ID '[' ']'  */
#line 191 "bc.y"
                                {(yyval.str) = code("%s", ary((yyvsp[-2].id)));}
#line 1704 "bc.c"
    break;

  case 50: /* arglst: expr ',' arglst  */
#line 192 "bc.y"
                                {(yyval.str) = code("%s%s", (yyvsp[-2].str), (yyvsp[0].str));}
#line 1710 "bc.c"
    break;

  case 51: /* arglst: ID '[' ']' ',' arglst  */
#line 193 "bc.y"
                                {(yyval.str) = code("%s%s", ary((yyvsp[-4].id)), (yyvsp[0].str));}
#line 1716 "bc.c"
    break;

  case 52: /* cond: '(' rel ')'  */
#line 196 "bc.y"
                                {(yyval.str) = (yyvsp[-1].str);}
#line 1722 "bc.c"
    break;

  case 53: /* rel: expr  */
#line 199 "bc.y"
                                {(yyval.str) = code("%s 0!=", (yyvsp[0].str));}
#line 1728 "bc.c"
    break;

  case 54: /* rel: expr EQ expr  */
#line 200 "bc.y"
                                {(yyval.str) = code("%s%s=", (yyvsp[-2].str), (yyvsp[0].str));}
#line 1734 "bc.c"
    break;

  case 55: /* rel: expr LE expr  */
#line 201 "bc.y"
                                {(yyval.str) = code("%s%s!<", (yyvsp[-2].str), (yyvsp[0].str));}
#line 1740 "bc.c"
    break;

  case 56: /* rel: expr GE expr  */
#line 202 "bc.y"
                                {(yyval.str) = code("%s%s!>", (yyvsp[-2].str), (yyvsp[0].str));}
#line 1746 "bc.c"
    break;

  case 57: /* rel: expr NE expr  */
#line 203 "bc.y"
                                {(yyval.str) = code("%s%s!=", (yyvsp[-2].str), (yyvsp[0].str));}
#line 1752 "bc.c"
    break;

  case 58: /* rel: expr '<' expr  */
#line 204 "bc.y"
                                {(yyval.str) = code("%s%s>", (yyvsp[-2].str), (yyvsp[0].str));}
#line 1758 "bc.c"
    break;

  case 59: /* rel: expr '>' expr  */
#line 205 "bc.y"
                                {(yyval.str) = code("%s%s<", (yyvsp[-2].str), (yyvsp[0].str));}
#line 1764 "bc.c"
    break;

  case 60: /* exprstat: nexpr  */
#line 208 "bc.y"
                                {(yyval.str) = code("%s%ss.", (yyvsp[0].str), code(sflag ? "" : "p"));}
#line 1770 "bc.c"
    break;

  case 61: /* exprstat: assign  */
#line 209 "bc.y"
                                {(yyval.str) = code("%ss.", (yyvsp[0].str));}
#line 1776 "bc.c"
    break;

  case 64: /* nexpr: NUMBER  */
#line 216 "bc.y"
                                {(yyval.str) = code(" %s", code((yyvsp[0].str)));}
#line 1782 "bc.c"
    break;

  case 65: /* nexpr: ID  */
#line 217 "bc.y"
                                {(yyval.str) = code("l%s", var((yyvsp[0].id)));}
#line 1788 "bc.c"
    break;

  case 66: /* nexpr: DOT  */
#line 218 "bc.y"
                                {(yyval.str) = code("l.");}
#line 1794 "bc.c"
    break;

  case 67: /* nexpr: SCALE  */
#line 219 "bc.y"
                                {(yyval.str) = code("K");}
#line 1800 "bc.c"
    break;

  case 68: /* nexpr: IBASE  */
#line 220 "bc.y"
                                {(yyval.str) = code("I");}
#line 1806 "bc.c"
    break;

  case 69: /* nexpr: OBASE  */
#line 221 "bc.y"
                                {(yyval.str) = code("O");}
#line 1812 "bc.c"
    break;

  case 70: /* nexpr: ID ary  */
#line 222 "bc.y"
                                {(yyval.str) = code("%s;%s", (yyvsp[0].str), ary((yyvsp[-1].id)));}
#line 1818 "bc.c"
    break;

  case 71: /* nexpr: '(' expr ')'  */
#line 223 "bc.y"
                                {(yyval.str) = (yyvsp[-1].str);}
#line 1824 "bc.c"
    break;

  case 72: /* nexpr: ID '(' arglst ')'  */
#line 224 "bc.y"
                                {(yyval.str) = code("%sl%sx", (yyvsp[-1].str), ftn((yyvsp[-3].id)));}
#line 1830 "bc.c"
    break;

  case 73: /* nexpr: ID '(' ')'  */
#line 225 "bc.y"
                                {(yyval.str) = code("l%sx", ftn((yyvsp[-2].id)));}
#line 1836 "bc.c"
    break;

  case 74: /* nexpr: '-' expr  */
#line 226 "bc.y"
                                {(yyval.str) = code("0%s-", (yyvsp[0].str));}
#line 1842 "bc.c"
    break;

  case 75: /* nexpr: expr '+' expr  */
#line 227 "bc.y"
                                {(yyval.str) = code("%s%s+", (yyvsp[-2].str), (yyvsp[0].str));}
#line 1848 "bc.c"
    break;

  case 76: /* nexpr: expr '-' expr  */
#line 228 "bc.y"
                                {(yyval.str) = code("%s%s-", (yyvsp[-2].str), (yyvsp[0].str));}
#line 1854 "bc.c"
    break;

  case 77: /* nexpr: expr '*' expr  */
#line 229 "bc.y"
                                {(yyval.str) = code("%s%s*", (yyvsp[-2].str), (yyvsp[0].str));}
#line 1860 "bc.c"
    break;

  case 78: /* nexpr: expr '/' expr  */
#line 230 "bc.y"
                                {(yyval.str) = code("%s%s/", (yyvsp[-2].str), (yyvsp[0].str));}
#line 1866 "bc.c"
    break;

  case 79: /* nexpr: expr '%' expr  */
#line 231 "bc.y"
                                {(yyval.str) = code("%s%s%%", (yyvsp[-2].str), (yyvsp[0].str));}
#line 1872 "bc.c"
    break;

  case 80: /* nexpr: expr '^' expr  */
#line 232 "bc.y"
                                {(yyval.str) = code("%s%s^", (yyvsp[-2].str), (yyvsp[0].str));}
#line 1878 "bc.c"
    break;

  case 81: /* nexpr: LENGTH '(' expr ')'  */
#line 233 "bc.y"
                                {(yyval.str) = code("%sZ", (yyvsp[-1].str));}
#line 1884 "bc.c"
    break;

  case 82: /* nexpr: SQRT '(' expr ')'  */
#line 234 "bc.y"
                                {(yyval.str) = code("%sv", (yyvsp[-1].str));}
#line 1890 "bc.c"
    break;

  case 83: /* nexpr: SCALE '(' expr ')'  */
#line 235 "bc.y"
                                {(yyval.str) = code("%sX", (yyvsp[-1].str));}
#line 1896 "bc.c"
    break;

  case 84: /* nexpr: INCDEC ID  */
#line 236 "bc.y"
                                {(yyval.str) = code("l%s1%sds%s", var((yyvsp[0].id)), code((yyvsp[-1].str)), var((yyvsp[0].id)));}
#line 1902 "bc.c"
    break;

  case 85: /* nexpr: INCDEC SCALE  */
#line 237 "bc.y"
                                {(yyval.str) = code("K1%sk", code((yyvsp[-1].str)));}
#line 1908 "bc.c"
    break;

  case 86: /* nexpr: INCDEC IBASE  */
#line 238 "bc.y"
                                {(yyval.str) = code("I1%sdi", code((yyvsp[-1].str)));}
#line 1914 "bc.c"
    break;

  case 87: /* nexpr: INCDEC OBASE  */
#line 239 "bc.y"
                                {(yyval.str) = code("O1%sdo", code((yyvsp[-1].str)));}
#line 1920 "bc.c"
    break;

  case 88: /* nexpr: INCDEC ID ary  */
#line 240 "bc.y"
                                {(yyval.str) = code("%sdS_;%s1%sdL_:%s", (yyvsp[0].str), ary((yyvsp[-1].id)), code((yyvsp[-2].str)), ary((yyvsp[-1].id)));}
#line 1926 "bc.c"
    break;

  case 89: /* nexpr: ID INCDEC  */
#line 241 "bc.y"
                                {(yyval.str) = code("l%sd1%ss%s", var((yyvsp[-1].id)), code((yyvsp[0].str)), var((yyvsp[-1].id)));}
#line 1932 "bc.c"
    break;

  case 90: /* nexpr: SCALE INCDEC  */
#line 242 "bc.y"
                                {(yyval.str) = code("Kd1%sk", code((yyvsp[0].str)));}
#line 1938 "bc.c"
    break;

  case 91: /* nexpr: IBASE INCDEC  */
#line 243 "bc.y"
                                {(yyval.str) = code("Id1%si", code((yyvsp[0].str)));}
#line 1944 "bc.c"
    break;

  case 92: /* nexpr: OBASE INCDEC  */
#line 244 "bc.y"
                                {(yyval.str) = code("Od1%so", code((yyvsp[0].str)));}
#line 1950 "bc.c"
    break;

  case 93: /* nexpr: ID ary INCDEC  */
#line 245 "bc.y"
                                {(yyval.str) = code("%sds.;%sd1%sl.:%s", (yyvsp[-1].str), ary((yyvsp[-2].id)), code((yyvsp[0].str)), ary((yyvsp[-2].id)));}
#line 1956 "bc.c"
    break;

  case 94: /* assign: ID '=' expr  */
#line 248 "bc.y"
                                {(yyval.str) = code("%sds%s", (yyvsp[0].str), var((yyvsp[-2].id)));}
#line 1962 "bc.c"
    break;

  case 95: /* assign: SCALE '=' expr  */
#line 249 "bc.y"
                                {(yyval.str) = code("%sdk", (yyvsp[0].str));}
#line 1968 "bc.c"
    break;

  case 96: /* assign: IBASE '=' expr  */
#line 250 "bc.y"
                                {(yyval.str) = code("%sdi", (yyvsp[0].str));}
#line 1974 "bc.c"
    break;

  case 97: /* assign: OBASE '=' expr  */
#line 251 "bc.y"
                                {(yyval.str) = code("%sdo", (yyvsp[0].str));}
#line 1980 "bc.c"
    break;

  case 98: /* assign: ID ary '=' expr  */
#line 252 "bc.y"
                                {(yyval.str) = code("%sd%s:%s", (yyvsp[0].str), (yyvsp[-2].str), ary((yyvsp[-3].id)));}
#line 1986 "bc.c"
    break;

  case 99: /* assign: ID EQOP expr  */
#line 253 "bc.y"
                                {(yyval.str) = code("%sl%s%sds%s", (yyvsp[0].str), var((yyvsp[-2].id)), code((yyvsp[-1].str)), var((yyvsp[-2].id)));}
#line 1992 "bc.c"
    break;

  case 100: /* assign: SCALE EQOP expr  */
#line 254 "bc.y"
                                {(yyval.str) = code("%sK%sdk", (yyvsp[0].str), code((yyvsp[-1].str)));}
#line 1998 "bc.c"
    break;

  case 101: /* assign: IBASE EQOP expr  */
#line 255 "bc.y"
                                {(yyval.str) = code("%sI%sdi", (yyvsp[0].str), code((yyvsp[-1].str)));}
#line 2004 "bc.c"
    break;

  case 102: /* assign: OBASE EQOP expr  */
#line 256 "bc.y"
                                {(yyval.str) = code("%sO%sdo", (yyvsp[0].str), code((yyvsp[-1].str)));}
#line 2010 "bc.c"
    break;

  case 103: /* assign: ID ary EQOP expr  */
#line 257 "bc.y"
                                {(yyval.str) = code("%s%sds.;%s%sdl.:s", (yyvsp[0].str), (yyvsp[-2].str), ary((yyvsp[-3].id)), code((yyvsp[-1].str)), ary((yyvsp[-3].id)));}
#line 2016 "bc.c"
    break;

  case 104: /* ary: '[' expr ']'  */
#line 260 "bc.y"
                                {(yyval.str) = (yyvsp[-1].str);}
#line 2022 "bc.c"
    break;


#line 2026 "bc.c"

      default: break;
    }
  /* User semantic actions sometimes alter yychar, and that requires
     that yytoken be updated with the new translation.  We take the
     approach of translating immediately before every use of yytoken.
     One alternative is translating here after every semantic action,
     but that translation would be missed if the semantic action invokes
     YYABORT, YYACCEPT, or YYERROR immediately after altering yychar or
     if it invokes YYBACKUP.  In the case of YYABORT or YYACCEPT, an
     incorrect destructor might then be invoked immediately.  In the
     case of YYERROR or YYBACKUP, subsequent parser actions might lead
     to an incorrect destructor call or verbose syntax error message
     before the lookahead is translated.  */
  YY_SYMBOL_PRINT ("-> $$ =", YY_CAST (yysymbol_kind_t, yyr1[yyn]), &yyval, &yyloc);

  YYPOPSTACK (yylen);
  yylen = 0;

  *++yyvsp = yyval;

  /* Now 'shift' the result of the reduction.  Determine what state
     that goes to, based on the state we popped back to and the rule
     number reduced by.  */
  {
    const int yylhs = yyr1[yyn] - YYNTOKENS;
    const int yyi = yypgoto[yylhs] + *yyssp;
    yystate = (0 <= yyi && yyi <= YYLAST && yycheck[yyi] == *yyssp
               ? yytable[yyi]
               : yydefgoto[yylhs]);
  }

  goto yynewstate;


/*--------------------------------------.
| yyerrlab -- here on detecting error.  |
`--------------------------------------*/
yyerrlab:
  /* Make sure we have latest lookahead translation.  See comments at
     user semantic actions for why this is necessary.  */
  yytoken = yychar == YYEMPTY ? YYSYMBOL_YYEMPTY : YYTRANSLATE (yychar);
  /* If not already recovering from an error, report this error.  */
  if (!yyerrstatus)
    {
      ++yynerrs;
      yyerror (YY_("syntax error"));
    }

  if (yyerrstatus == 3)
    {
      /* If just tried and failed to reuse lookahead token after an
         error, discard it.  */

      if (yychar <= YYEOF)
        {
          /* Return failure if at end of input.  */
          if (yychar == YYEOF)
            YYABORT;
        }
      else
        {
          yydestruct ("Error: discarding",
                      yytoken, &yylval);
          yychar = YYEMPTY;
        }
    }

  /* Else will try to reuse lookahead token after shifting the error
     token.  */
  goto yyerrlab1;


/*---------------------------------------------------.
| yyerrorlab -- error raised explicitly by YYERROR.  |
`---------------------------------------------------*/
yyerrorlab:
  /* Pacify compilers when the user code never invokes YYERROR and the
     label yyerrorlab therefore never appears in user code.  */
  if (0)
    YYERROR;
  ++yynerrs;

  /* Do not reclaim the symbols of the rule whose action triggered
     this YYERROR.  */
  YYPOPSTACK (yylen);
  yylen = 0;
  YY_STACK_PRINT (yyss, yyssp);
  yystate = *yyssp;
  goto yyerrlab1;


/*-------------------------------------------------------------.
| yyerrlab1 -- common code for both syntax error and YYERROR.  |
`-------------------------------------------------------------*/
yyerrlab1:
  yyerrstatus = 3;      /* Each real token shifted decrements this.  */

  /* Pop stack until we find a state that shifts the error token.  */
  for (;;)
    {
      yyn = yypact[yystate];
      if (!yypact_value_is_default (yyn))
        {
          yyn += YYSYMBOL_YYerror;
          if (0 <= yyn && yyn <= YYLAST && yycheck[yyn] == YYSYMBOL_YYerror)
            {
              yyn = yytable[yyn];
              if (0 < yyn)
                break;
            }
        }

      /* Pop the current state because it cannot handle the error token.  */
      if (yyssp == yyss)
        YYABORT;


      yydestruct ("Error: popping",
                  YY_ACCESSING_SYMBOL (yystate), yyvsp);
      YYPOPSTACK (1);
      yystate = *yyssp;
      YY_STACK_PRINT (yyss, yyssp);
    }

  YY_IGNORE_MAYBE_UNINITIALIZED_BEGIN
  *++yyvsp = yylval;
  YY_IGNORE_MAYBE_UNINITIALIZED_END


  /* Shift the error token.  */
  YY_SYMBOL_PRINT ("Shifting", YY_ACCESSING_SYMBOL (yyn), yyvsp, yylsp);

  yystate = yyn;
  goto yynewstate;


/*-------------------------------------.
| yyacceptlab -- YYACCEPT comes here.  |
`-------------------------------------*/
yyacceptlab:
  yyresult = 0;
  goto yyreturnlab;


/*-----------------------------------.
| yyabortlab -- YYABORT comes here.  |
`-----------------------------------*/
yyabortlab:
  yyresult = 1;
  goto yyreturnlab;


/*-----------------------------------------------------------.
| yyexhaustedlab -- YYNOMEM (memory exhaustion) comes here.  |
`-----------------------------------------------------------*/
yyexhaustedlab:
  yyerror (YY_("memory exhausted"));
  yyresult = 2;
  goto yyreturnlab;


/*----------------------------------------------------------.
| yyreturnlab -- parsing is finished, clean up and return.  |
`----------------------------------------------------------*/
yyreturnlab:
  if (yychar != YYEMPTY)
    {
      /* Make sure we have latest lookahead translation.  See comments at
         user semantic actions for why this is necessary.  */
      yytoken = YYTRANSLATE (yychar);
      yydestruct ("Cleanup: discarding lookahead",
                  yytoken, &yylval);
    }
  /* Do not reclaim the symbols of the rule whose action triggered
     this YYABORT or YYACCEPT.  */
  YYPOPSTACK (yylen);
  YY_STACK_PRINT (yyss, yyssp);
  while (yyssp != yyss)
    {
      yydestruct ("Cleanup: popping",
                  YY_ACCESSING_SYMBOL (+*yyssp), yyvsp);
      YYPOPSTACK (1);
    }
#ifndef yyoverflow
  if (yyss != yyssa)
    YYSTACK_FREE (yyss);
#endif

  return yyresult;
}

#line 263 "bc.y"

static int
yyerror(char *s)
{
	fprintf(stderr, "bc: %s:%d: %s\n", filename, lineno, s);
	nerr++;
	longjmp(recover, 1);
}

static void
writeout(char *s)
{
	if (write(1, s, strlen(s)) < 0)
		goto err;
	if (write(1, "\n", 1) < 0)
		goto err;
	free(s);
	return;
	
err:
	eprintf("writing to dc:");
}

static char *
code(char *fmt, ...)
{
	char *s, *t;
	va_list ap;
	int c, len, room;

	va_start(ap, fmt);
	room = BUFSIZ;
	for (s = buff; *fmt; s += len) {
		len = 1;
		if ((c = *fmt++) != '%')
			goto append;

		switch (*fmt++) {
		case 'd':
			c = va_arg(ap, int);
			len = snprintf(s, room, "%d", c);
			if (len < 0 || len >= room)
				goto err;
			break;
		case 'c':
			c = va_arg(ap, int);
			goto append;
		case 's':
			t = va_arg(ap, void *);
			len = strlen(t);
			if (len >= room)
				goto err;
			memcpy(s, t, len);
			free(t);
			break;
		case '%':
		append:
			if (room <= 1)
				goto err;
			*s = c;
			break;
		default:
			abort();
		}

		room -= len;
	}
	va_end(ap);

	*s = '\0';
	return estrdup(buff);

err:
	eprintf("unable to code requested operation\n");
	return NULL;
}

static Macro *
macro(int op)
{
	int preop;
	Macro *d, *p;

	if (nested == NESTED_MAX)
		yyerror("too much nesting");

	d = &macros[nested];
	d->op = op;
	d->nested = nested++;
	d->name = NULL;

	switch (op) {
	case HOME:
		d->id = 0;
		d->flowid = flowid;
		inhome = 1;
		break;
	case DEF:
		unwind = estrdup("");
		inhome = 0;
		d->id = funid(yytext);
		d->name = estrdup(yytext);
		d->flowid = macros[0].flowid;
		break;
	default:
		assert(nested > 1);
		preop = d[-1].op;
		d->flowid = d[-1].flowid;
		if (preop != HOME && preop != DEF) {
			if (d->flowid == 255)
				eprintf("too many control flow structures");
			d->flowid++;
		}
		d->id = d->flowid;
		if (!inhome) {
			/* populate reserved id */
			flowid = d->flowid;
			for (p = d; p != macros; --p)
				p[-1].flowid++;
		}
		break;
	}

	return d;
}

static char *
decl(int type, char *list, char *id)
{
	char *i1, *i2;

	i1 = estrdup(id);
	i2 = estrdup(id);
	free(id);

	if (!list)
		list = estrdup("");

	unwind = code("%sL%ss.", unwind, i1);

	return code((type == AUTO) ? "0S%s%s" : "S%s%s", i2, list);
}

static char *
param(char *list, char *id)
{
	return decl(PARAM, list, id);
}

static char *
local(char *list, char *id)
{
	return decl(AUTO, list, id);
}

static char *
funcode(Macro *d, char *params, char *vars, char *body)
{
	char *s;

	if (strlen(d->name) > 1) {
		s = code("[%s%s%s%s]s\"()%s\"",
			 vars, params,
			 body,
			 retcode(code(" 0")),
			 d->name);
	} else {
		s = code(sflag ? "[%s%s%s%s]s<%d>" : "[%s%s%s%s]s%c",
			 vars, params,
			 body,
			 retcode(code(" 0")),
			 d->id);
		free(d->name);
	}

	free(unwind);
	unwind = NULL;
	nested--;
	inhome = 0;

	return s;
}

static char *
brkcode(void)
{
	Macro *d;

	for (d = &macros[nested-1]; d->op != HOME && d->op != LOOP; --d)
		;
	if (d->op == HOME)
		yyerror("break not in for or while");
	return code(" %dQ", nested  - d->nested);
}

static char *
forcode(Macro *d, char *init, char *cmp, char *inc, char *body)
{
	char *s;

	s = code(sflag ? "[%s%ss.%s<%d>]s<%d>" : "[%s%ss.%s%c]s%c",
	         body,
	         inc,
	         estrdup(cmp),
	         d->id, d->id);
	writeout(s);

	s = code(sflag ? "%ss.%s<%d> " : "%ss.%s%c ",
	         init,
	         cmp,
	         d->id);
	nested--;

	return s;
}

static char *
whilecode(Macro *d, char *cmp, char *body)
{
	char *s;

	s = code(sflag ? "[%s%s<%d>]s<%d>" : "[%s%s%c]s%c",
	         body,
	         estrdup(cmp),
	         d->id, d->id);
	writeout(s);

	s = code(sflag ? "%s<%d> " : "%s%c ",
	         cmp, d->id);
	nested--;

	return s;
}

static char *
ifcode(Macro *d, char *cmp, char *body)
{
	char *s;

	s = code(sflag ? "[%s]s<%d>" : "[%s]s%c",
	         body, d->id);
	writeout(s);

	s = code(sflag ? "%s<%d> " : "%s%c ",
	         cmp, d->id);
	nested--;

	return s;
}

static char *
retcode(char *expr)
{
	char *s;

	if (nested < 2 || macros[1].op != DEF)
		yyerror("return must be in a function");
	return code("%s %s %dQ", expr, estrdup(unwind), nested - 1);
}

static char *
ary(char *s)
{
	if (strlen(s) == 1)
		return code("%c", toupper(s[0]));
	return code("\"[]%s\"", estrdup(s));
}

static char *
ftn(char *s)
{
	if (strlen(s) == 1)
		return code(sflag ? "<%d>" : "%c", funid(s));
	return code("\"()%s\"", estrdup(s));
}

static char *
var(char *s)
{
	if (strlen(s) == 1)
		return code(s);
	return code("\"%s\"", estrdup(s));
}

static void
quit(void)
{
	exit(nerr > 0 ? 1 : 0);
}

static void
skipspaces(void)
{
	int ch;

	while (isascii(ch = getc(filep)) && isspace(ch)) {
		if (ch == '\n') {
			lineno++;
			break;
		}
	}
	ungetc(ch, filep);
}

static int
iden(int ch)
{
	static struct keyword {
		char *str;
		int token;
	} keywords[] = {
		{"define", DEF},
		{"break", BREAK},
		{"quit", QUIT},
		{"length", LENGTH},
		{"return", RETURN},
		{"for", FOR},
		{"if", IF},
		{"while", WHILE},
		{"sqrt", SQRT},
		{"scale", SCALE},
		{"ibase", IBASE},
		{"obase", OBASE},
		{"auto", AUTO},
		{"print", PRINT},
		{NULL}
	};
	struct keyword *p;
	char *bp;

	ungetc(ch, filep);
	for (bp = yytext; bp < &yytext[BUFSIZ]; ++bp) {
		ch = getc(filep);
		if (!isascii(ch) || !islower(ch))
			break;
		*bp = ch;
	}

	if (bp == &yytext[BUFSIZ])
		yyerror("too long token");
	*bp = '\0';
	ungetc(ch, filep);

	if (strlen(yytext) == 1) {
		strcpy(yylval.id, yytext);
		return ID;
	}

	for (p = keywords; p->str && strcmp(p->str, yytext); ++p)
		;
	if (p->str)
		return p->token;

	if (!sflag)
		yyerror("invalid keyword");
	strcpy(yylval.id, yytext);
	return ID;
}

static char *
digits(char *bp)
{
	int ch;
	char *digits = DIGITS, *p;

	while (bp < &yytext[BUFSIZ]) {
		ch = getc(filep);
		p = strchr(digits, ch);
		if (!p)
			break;
		*bp++ = ch;
	}

	if (bp == &yytext[BUFSIZ])
		return NULL;
	ungetc(ch, filep);

	return bp;
}

static int
number(int ch)
{
	int d;
	char *bp;

	ungetc(ch, filep);
	if ((bp = digits(yytext)) == NULL)
		goto toolong;

	if ((ch = getc(filep)) != '.') {
		ungetc(ch, filep);
		goto end;
	}
	*bp++ = '.';

	if ((bp = digits(bp)) == NULL)
		goto toolong;

end:
	if (bp ==  &yytext[BUFSIZ])
		goto toolong;
	*bp = '\0';
	yylval.str = yytext;

	return NUMBER;

toolong:
	yyerror("too long number");
	return 0;
}

static int
string(int ch)
{
	char *bp;

	for (bp = yytext; bp < &yytext[BUFSIZ]; ++bp) {
		if ((ch = getc(filep)) == '"')
			break;
		*bp = ch;
	}

	if (bp == &yytext[BUFSIZ])
		yyerror("too long string");
	*bp = '\0';
	yylval.str = estrdup(yytext);

	return STRING;
}

static int
follow(int next, int yes, int no)
{
	int ch;

	ch = getc(filep);
	if (ch == next)
		return yes;
	ungetc(ch, filep);
	return no;
}

static int
operand(int ch)
{
	int peekc;

	switch (ch) {
	case '\n':
	case '{':
	case '}':
	case '[':
	case ']':
	case '(':
	case ')':
	case ',':
	case ';':
		return ch;
	case '.':
		peekc = ungetc(getc(filep), filep);
		if (strchr(DIGITS, peekc))
			return number(ch);
		return DOT;
	case '"':
		return string(ch);
	case '*':
		yylval.str = "*";
		return follow('=', EQOP, '*');
	case '/':
		yylval.str = "/";
		return follow('=', EQOP, '/');
	case '%':
		yylval.str = "%";
		return follow('=', EQOP, '%');
	case '=':
		return follow('=', EQ, '=');
	case '+':
	case '-':
		yylval.str = (ch == '+') ? "+" : "-";
		if (follow('=', EQOP, ch) != ch)
			return EQOP;
		return follow(ch, INCDEC, ch);
	case '^':
		yylval.str = "^";
		return follow('=', EQOP, '^');
	case '<':
		return follow('=', LE, '<');
	case '>':
		return follow('=', GE, '>');
	case '!':
		if (getc(filep) == '=')
			return NE;
	default:
		yyerror("invalid operand");
		return 0;
	}
}

static void
comment(void)
{
	int c;

	for (;;) {
		while ((c = getc(filep)) != '*') {
			if (c == '\n')
				lineno++;
		}
		if ((c = getc(filep)) == '/')
			break;
		ungetc(c, filep);
	}
}

static int
yylex(void)
{
	int peekc, ch;

repeat:
	skipspaces();

	ch = getc(filep);
	if (ch == EOF) {
		return EOF;
	} else if (!isascii(ch)) {
		yyerror("invalid input character");
	} else if (islower(ch)) {
		return iden(ch);
	} else if (strchr(DIGITS, ch)) {
		return number(ch);
	} else {
		if (ch == '/') {
			peekc = getc(filep);
			if (peekc == '*') {
				comment();
				goto repeat;
			}
			ungetc(peekc, filep);
		}
		return operand(ch);
	}

	return 0;
}

static void
spawn(void)
{
	int fds[2];
	char *par = sflag ? "-i" : NULL;
	char errmsg[] = "bc:error execing dc\n";

	if (pipe(fds) < 0)
		eprintf("creating pipe:");

	switch (fork()) {
	case -1:
		eprintf("forking dc:");
	case 0:
		close(1);
		dup(fds[1]);
		close(fds[0]);
		close(fds[1]);
		break;
	default:
		close(0);
		dup(fds[0]);
		close(fds[0]);
		close(fds[1]);
		execlp(dcprog, "dc", par, (char *) NULL);

		/* it shouldn't happen */
		write(3, errmsg, sizeof(errmsg)-1);
		_Exit(2);
	}
}

static void
run(void)
{
	if (setjmp(recover)) {
		if (ferror(filep))
			eprintf("%s:", filename);
		if (feof(filep))
			return;
	}
	yyparse();
}

static void
bc(char *fname)
{
	Macro *d;

	lineno = 1;
	nested = 0;

	macro(HOME);
	if (!fname) {
		filename = "<stdin>";
		filep = stdin;
	} else {
		filename = fname;
		if ((filep = fopen(fname, "r")) == NULL)
			eprintf("%s:", fname);
	}

	run();
	fclose(filep);
}

static void
usage(void)
{
	eprintf("usage: %s [-p dc][-cdls]\n", argv0);
}

int
main(int argc, char *argv[])
{
	ARGBEGIN {
	case 'p':
		dcprog = EARGF(usage());
		break;
	case 'c':
		cflag = 1;
		break;
	case 'd':
		dflag = 1;
		yydebug = 3;
		break;
	case 'l':
		lflag = 1;
		break;
	case 's':
		sflag = 1;
		break;
	default:
		usage();
	} ARGEND

	yytext = malloc(BUFSIZ);
	buff = malloc(BUFSIZ);
	if (!yytext || !buff)
		eprintf("out of memory\n");
	flowid = 128;

	if (!cflag)
		spawn();
	if (lflag)
		bc(PREFIX "/share/misc/bc.library");

	while (*argv)
		bc(*argv++);
	bc(NULL);

	quit();
}
