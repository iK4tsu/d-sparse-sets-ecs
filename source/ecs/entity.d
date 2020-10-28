module ecs.entity;

import std.exception : basicExceptionCtors;

version(unittest) import aurorafw.unit.assertion;


/**
 * Trait which checks if a type is a valid entity type. An entity type must be
 *     unsigned and integral. These are all the accepted types: ***ubyte, ushort,
 *     uint, ulong***.
 *
 * Params: T = a type to be validated.
 *
 * Returns: `true` if is a valid type, `false` otherwise
 */
public template isEntityType(T)
{
	import std.traits : isUnsigned, isIntegral;
	enum isEntityType = isUnsigned!T && isIntegral!T;
}


@safe pure
@("entity: isEntityType")
unittest
{
	import std.meta : AliasSeq;
	static foreach(t; AliasSeq!(ubyte, ushort, uint, ulong))
	{
		assertTrue(isEntityType!t);
	}

	struct Foo {}
	static foreach(t; AliasSeq!(byte, short, int, long, char, dchar, string, dstring, float, double, Foo))
	{
		assertFalse(isEntityType!t);
	}
}


/**
 * Trait which checks if a bit id amount is valid for a certaint entity type.
 *
 * Params:
 *     T = entity type used for validation.
 *     idBitAmount = bit amount to validate.
 *
 * Returns: `true` if amount is between 1 and T.sizeof * 8, `false` otherwise.
 *
 * See_Also: $(LREF isEntityType)
 */
package template isValidBitIdAmount(T, T idBitAmount)
	if (isEntityType!T)
{
	enum isValidBitIdAmount = idBitAmount < T.sizeof * 8 && idBitAmount > T.min;
}


@safe pure
@("entity: isValidBitIdAMount")
unittest
{
	import std.meta : AliasSeq;
	static foreach(t; AliasSeq!(ubyte, ushort, uint, ulong))
	{
		assertTrue(isValidBitIdAmount!(t, 1));
		assertTrue(isValidBitIdAmount!(t, t.sizeof * 8 - 1));

		assertFalse(isValidBitIdAmount!(t, t.min));
		assertFalse(isValidBitIdAmount!(t, t.sizeof * 8));
	}

	struct Foo {}
	static foreach(t; AliasSeq!(byte, short, int, long, char, dchar, string, dstring, float, double, Foo))
	{
		assertFalse(__traits(compiles, isValidBitIdAmount!(t, 1)));
	}
}


/**
 * Generate needed masks and shift values. \
 * These values are defined by the variable type and the amount of id bits you
 *     use. \
 * You can only generate masks and shift values of unsigned and integral types,
 *     ***ubyte, ushort, uint, ulong***. \
 * The amount is of type T meaning you cannot pass any value lower than 0 or
 *     higher than T.max; to complement these default type constraints you cannot
 *     pass a value equal to 0 as this would mean no space for ids or equal to
 *     T.sizeof * 8 as this would mean no space for batches. \
 * \
 * There are some default alises available for fast access.
 *
 * | alias-name | id-(bits) | batch-(bits) | max-entities  | batch-reset   |
 * | :--------- | :-------: | :----------: | :-----------: | :-----------: |
 * | Registry   | 20        | 12           | 1_048_574     | 4_096         |
 * | Registry8  | 4         | 4            | 14            | 16            |
 * | Registry16 | 8         | 8            | 254           | 256           |
 * | Registry32 | 16        | 16           | 65_534        | 65_536        |
 * | Registry64 | 32        | 32           | 4_294_967_295 | 4_294_967_296 |
 *
 * Registry:
 * + id: ***20 bits*** (max at `1_048_574`)
 * + batch: ***12 bits*** (resets at `4_096`)
 *
 * Registry8:
 * + id: ***4 bits*** (max at `14`)
 * + batch: ***4 bits*** (resets at `16`)
 *
 * Registry16:
 * + id: ***8 bits*** (max at `254`)
 * + batch: ***8 bits*** (resets at `256`)
 *
 * Registry32:
 * + id: ***16 bits*** (max at `65_534`)
 * + batch: ***16 bits*** (resets at `65_536`)
 *
 * Registry64:
 * + id: ***32 bits*** (max at `4_294_967_295`)
 * + batch: ***32 bits*** (resets at `4_294_967_296`)
 *
 * Params:
 *     T = entity type.
 *     idBitAmount = number of bits reserved for the id.
 *
 * Code_Generation:
 * + `entityShift` = the shift value needed to access the batch.
 * + `entityMask` = the mask to extract the entity id.
 * + `batchMask` = the mask to extract the entity batch.
 * + `entityNull` = reserved value to for representing an empty queue as well as
 *     the maximum of entities.
 *
 * See_Also: $(LREF isEntityType), $(LREF isValidBitIdAmount)
 */
package mixin template genEntityBitMasks(T, T idBitAmount)
	if(isEntityType!T && isValidBitIdAmount!(T, idBitAmount))
{
	public enum T entityShift = idBitAmount;
	public enum T entityMask = (1UL << idBitAmount) - 1;
	public enum T batchMask = (1UL << (T.sizeof * 8 - idBitAmount)) - 1;
	public enum T entityNull = entityMask;
}


@safe pure
@("entity: genEntityBitMasks")
unittest
{
	assertFalse(__traits(compiles, genEntityBitMasks!(uint, uint.min)));
	assertFalse(__traits(compiles, genEntityBitMasks!(uint, uint.sizeof * 8)));

	mixin genEntityBitMasks!(uint, 4);
	assertEquals(4, entityShift);
	assertEquals(0xF, entityMask);
	assertEquals(0xFFFF_FFF, batchMask);
	assertEquals(0xF, entityNull);
}


/**
 * Simple exception for entity errors.
 */
public class EntityException : Exception
{
	mixin basicExceptionCtors;
}


///
public class InvalidEntityException : EntityException
{
	mixin basicExceptionCtors;
}


///
public final class MaximumEntitiesReachedException : EntityException
{
	mixin basicExceptionCtors;
}


///
public final class EntityNotInPoolException : InvalidEntityException
{
	mixin basicExceptionCtors;
}


///
public final class EntityInPoolException : InvalidEntityException
{
	mixin basicExceptionCtors;
}
