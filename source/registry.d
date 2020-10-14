module registry;

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
private template isEntityType(T)
{
	import std.traits : isUnsigned, isIntegral;
	enum isEntityType = isUnsigned!T && isIntegral!T;
}


/**
 * Trait which checks if a bit id amount is valid for a certaint entity type.
 *
 * Params:
 *     T = entity type used for validation.
 *     amount = bit amount to validate.
 *
 * Returns: `true` if amount is between 1 and T.sizeof * 8, `false` otherwise.
 *
 * See_Also: $(LREF isEntityType)
 */
private template isValidBitIdAmount(T, T amount)
	if (isEntityType!T)
{
	enum isValidBitIdAmount = amount < T.sizeof * 8 && amount > 0;
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
 *     amount = number of bits reserved for the id.
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
private mixin template genEntityBitMasks(T, T amount)
	if(isEntityType!T && isValidBitIdAmount!(T, amount))
{
	public enum T entityShift = amount;
	public enum T entityMask = (1UL << amount) - 1;
	public enum T batchMask = (1UL << (T.sizeof * 8 - amount)) - 1;
	public enum T entityNull = entityMask;
}


/**
 * Simple exception for entity errors.
 */
class EntityException : Exception
{
	mixin basicExceptionCtors;
}


///
class InvalidEntityException : EntityException
{
	mixin basicExceptionCtors;
}


///
class MaximumEntitiesReachedException : EntityException
{
	mixin basicExceptionCtors;
}


@nogc @safe pure
class BasicRegistry(T, T idBitQuantity)
	if(isEntityType!T)
{
	import std.container : Array;
	import std.conv : to;
	import std.exception : enforce;

	mixin genEntityBitMasks!(T, idBitQuantity);

public:
	this() {}


	/**
	 * Create a new entity either by spawning a new id or reusing one in the
	 *     queue.
	 *
	 * Returns: a new entity reference with a reused id if the queue isn't
	 *     empty or with a new spawned id otherwise.
	 *
	 * See_Also: $(LREF spawn), $(LREF revive), $(LREF discard)
	 */
	@safe pure
	@property const(T) create()
	{
		return queue == entityNull ? spawn : revive;
	}


	/**
	 * Destroy a valid entity and update the batch. \
	 * When an entity is discarded it's batch is updated and stored. This will be
	 *     used when the destroyed id is reused.
	 *
	 * Params: entity = entity to be destroyed.
	 *
	 * See_Also: $(LREF create), $(LREF spawn), $(LREF revive), $(LREF idOf),
	 *     $(LREF updateBatch) to understand how it updates
	 */
	@safe pure
	void discard(const inout(T) entity)
	{
		enforce!InvalidEntityException(isValid(entity), "Cannot discard entity with invalid id!");
		const id = idOf(entity);
		const batch = updateBatch(entity);
		entities[id] = cast(T)(queue | (batch << entityShift));
		queue = id;
	}


	/**
	 * Get the batch of any valid or invalid entity's reference.
	 *
	 * Params: entity = reference from which the batch is going to be extracted.
	 *
	 * Returns: the entity's batch.
	 *
	 * See_Also: $(LREF currentBatchOf), $(LREF idOf)
	 */
	@safe pure
	inout(T) batchOf(const inout(T) entity) const inout
	{
		return entity >> entityShift;
	}


	/**
	 * Get the current batch of an entity reference id which has spawned. \
	 * If the extracted id of the given entity reference hasn't been spawned yet,
	 *     meaning the id hasn't been created, an EntityException will be thrown.
	 *
	 * Params: entity = refence once spawned from which the id is going to be
	 *     extracted.
	 *
	 * Throws: $(LREF EntityException) if the reference id has been created.
	 *
	 * Returns: the batch of the current id extracted from the entity's
	 *     reference.
	 *
	 * See_Also: $(LREF batchOf), $(LREF idOf)
	 */
	@safe pure
	inout(T) currentBatchOf(const inout(T) entity) const inout
	{
		enforce!InvalidEntityException(hasSpawned(entity), "Cannot extract the batch from an invalid entity!");
		return entities[idOf(entity)] >> entityShift;
	}


	/**
	 * Get the id of any valid or invalid entity's reference.
	 *
	 * Params: entity = reference from which the id is going to be extracted.
	 *
	 * Returns: the entity's id
	 *
	 * See_Also: $(LREF batchOf), $(LREF currentBatchOf)
	 */
	@safe pure
	inout(T) idOf(const inout(T) entity) const inout
	{
		return entity & entityMask;
	}


	/**
	 * Check if an entity's reference is valid. \
	 * A valid reference is defined by:
	 *
	 * * it's id must have been created byt this registry at some point.
	 * * the entity needs to be alive.
	 *
	 * Params: entity = reference to validate.
	 *
	 * Returns: `true` if valid, `false` otherwise.
	 *
	 * See_Also: $(LREF hasSpawned)
	 */
	@safe pure
	bool isValid(const inout(T) entity) const inout
	{
		return hasSpawned(entity) && entities[idOf(entity)] == entity;
	}


	/**
	 * Check if an entity's reference id has been created by this registry at
	 *     some point.
	 *
	 * Params: entity = reference from which the extracted id will be evaluated.
	 *
	 * Returns: `true` if the extracted id has been created, `false` otherwise.
	 *
	 * See_Also: $(LREF isValid)
	 */
	@safe pure
	bool hasSpawned(const inout(T) entity) const inout
	{
		return idOf(entity) < entities.length;
	}


private:
	/**
	 * Generate a new entity's id. \
	 * Every time a new id is spawned it's batch is set to 0.
	 *
	 * Returns: an entity with a new id.
	 *
	 * See_Also: $(LREF revive), $(LREF create), $(LREF discard)
	 */
	@trusted pure
	const(T) spawn()
	{
		enforce!MaximumEntitiesReachedException(entities.length < entityMask, "Maximum entities reached!");
		entities.insertBack(entities.length.to!T);
		return entities.back;
	}


	/**
	 * Generate a new entity with a reused id. \
	 * Whenever the queue isn't empty it's id is reused.
	 *
	 * Returns: an entity with a reused id.
	 *
	 * See_Also: $(LREF spawn), $(LREF create), $(LREF discard)
	 */
	@safe pure
	const(T) revive()
		in(queue != entityNull, "Must have dead entities to revive!")
	{
		const batch = batchOf(entities[queue]);
		const id = queue;
		queue = idOf(entities[id]);
		entities[id] = (id | (batch << entityShift)).to!T;
		return entities[id];
	}


	/**
	 * Increments the reference's batch of a valid entity by 1. \
	 * If the batch is at it's max value then it's reseted to 0.
	 *
	 * Params: entity = reference which batch is going to be updated.
	 *
	 * Returns: the new updated batch's value
	 *
	 * See_Also: $(LREF isValid), $(LREF batchOf), $(LREF currentBatchOf)
	 */
	@safe pure
	inout(T) updateBatch(const inout(T) entity) const inout
		in(isValid(entity))
	{
		const T batch = batchOf(entity);
		return batch == batchMask ? 0 : (batch + 1).to!T;
	}


	Array!T entities;
	T queue = entityNull;
}


/**
 * A registry with variable type of ***ulong***. \
 * This comes with:
 * + id: ***32 bits*** (max at `4_294_967_295`)
 * + batch: ***32 bits*** (resets at `4_294_967_296`)
 *
 * Examples:
 * --------------------
 * auto registry = Registry64();
 * --------------------
 */
alias Registry64 = BasicRegistry!(ulong, 32);

/**
 * A registry with variable type of ***uint***. \
 * This comes with:
 * + id: ***16 bits*** (max at `65_534`)
 * + batch: ***16 bits*** (resets at `65_536`)
 *
 * Examples:
 * --------------------
 * auto registry = Registry32();
 * --------------------
 */
alias Registry32 = BasicRegistry!(uint, 16);

/**
 * A registry with variable type of ***ushort***. \
 * This comes with:
 * + id: ***8 bits*** (max at `254`)
 * + batch: ***8 bits*** (resets at `256`)
 *
 * Examples:
 * --------------------
 * auto registry = Registry16();
 * --------------------
 */
alias Registry16 = BasicRegistry!(ushort, 8);

/**
 * A registry with variable type of ***ubyte***. \
 * This comes with:
 * + id: ***4 bits*** (max at `14`)
 * + batch: ***4 bits*** (resets at `16`)
 *
 * Examples:
 * --------------------
 * auto registry = Registry8();
 * --------------------
 */
alias Registry8 = BasicRegistry!(ubyte, 4);

/**
 * The default registry with variable type of ***uint***. \
 * This comes with:
 * + id: ***20 bits*** (max at `1_048_574`)
 * + batch: ***12 bits*** (resets at `4_096`)
 *
 * Examples:
 * --------------------
 * auto registry = Registry();
 * --------------------
 */
alias Registry = BasicRegistry!(uint, 20);


@safe pure
@("registry: batchOf")
unittest
{
	auto registry = new Registry();
	auto e0 = registry.create;
	assertEquals(0, registry.batchOf(e0));

	registry.discard(e0);
	assertEquals(0, registry.batchOf(e0));

	auto e1 = registry.create;
	assertEquals(1, registry.batchOf(e1));
	assertEquals(0, registry.batchOf(e0));
}


@safe pure
@("registry: currentBatchOf")
unittest
{
	auto registry = new Registry();
	auto e0 = registry.create;
	assertEquals(0, registry.currentBatchOf(e0));

	registry.discard(e0);
	assertEquals(1, registry.currentBatchOf(e0));
}


/**
 * This must be @trusted because std.container : Array is not @safe
 */
@trusted pure
@("registry: entities")
unittest
{
	import std.array : array;
	auto registry = new Registry();

	auto e0 = registry.create;
	auto e1 = registry.create;
	auto e2 = registry.create;

	assertEquals([e0, e1, e2], registry.entities.array);

	registry.discard(e1);
	const pos1 = registry.idOf(registry.entityNull) | (registry.currentBatchOf(e1) << registry.entityShift);
	assertEquals([e0, pos1, e2], registry.entities.array);

	registry.discard(e0);
	const pos0 = registry.idOf(e1) | (registry.currentBatchOf(e0) << registry.entityShift);
	assertEquals([pos0, pos1, e2], registry.entities.array);

	auto e01 = registry.create;
	auto e11 = registry.create;
	assertEquals([e01, e11, e2], registry.entities.array);
}


@safe pure
@("registry: hasSpawned")
unittest
{
	auto registry = new Registry();

	auto invalid = 0;
	assertFalse(registry.hasSpawned(invalid));

	auto e0 = registry.create;
	assertTrue(registry.hasSpawned(e0));

	registry.discard(e0);
	assertTrue(registry.hasSpawned(e0));
}


@safe pure
@("registry: idOf")
unittest
{
	auto registry = new Registry();

	auto e0 = registry.create;
	assertEquals(0, registry.idOf(e0));

	registry.discard(e0);
	assertEquals(0, registry.idOf(e0));

	auto e01 = registry.create;
	assertEquals(registry.idOf(e01), registry.idOf(e0));
	assertNotSame(e0, e01);
}


@safe pure
@("registry: isValid")
unittest
{
	auto registry = new Registry();

	auto invalid = 0;
	assertFalse(registry.isValid(invalid));

	auto e0 = registry.create;
	assertTrue(registry.isValid(e0));

	registry.discard(e0);
	assertFalse(registry.isValid(e0));

	auto e01 = registry.create;
	assertTrue(registry.isValid(e01));
	assertFalse(registry.isValid(e0));
}


@safe pure
@("registry: discard")
unittest
{
	auto registry = new Registry();
	const uint invalid = 1;
	auto exception = expectThrows!InvalidEntityException(registry.discard(invalid));
	assertEquals("Cannot discard entity with invalid id!", exception.msg);

	auto e0 = registry.create;
	registry.discard(e0);
	exception = expectThrows!InvalidEntityException(registry.discard(e0));
	assertEquals("Cannot discard entity with invalid id!", exception.msg);
}


@safe pure
@("registry: queue")
unittest
{
	auto registry = new Registry();
	assertSame(registry.entityNull, registry.queue);

	auto e0 = registry.create;
	auto e1 = registry.create;
	auto e2 = registry.create;

	registry.discard(e0);
	assertSame(e0, registry.queue);

	registry.discard(e2);
	assertSame(e2, registry.queue);

	registry.discard(e1);
	assertSame(e1, registry.queue);

	registry.create;
	assertSame(e2, registry.queue);

	registry.create;
	assertSame(e0, registry.queue);

	registry.create;
	assertSame(registry.entityNull, registry.queue);
}


private template registryReviveUnittest(T, T amount)
{
	enum registryReviveUnittest = q{
		auto registry = new BasicRegistry!(}~T.stringof~","~amount.stringof~q{);

		auto e0 = registry.create;
		registry.discard(e0);
		auto e1 = registry.create;
		assertNotSame(e1, e0);

		registry.discard(e1);
		auto e2 = registry.create;
		assertSame(e0, e2);
	};
}


@safe pure
@("registry: revive (ubyte)")
unittest
{
	mixin(registryReviveUnittest!(ubyte, 7));
}


@safe pure
@("registry: revive (ushort)")
unittest
{
	mixin(registryReviveUnittest!(ushort, 15));
}


@safe pure
@("registry: revive (uint)")
unittest
{
	mixin(registryReviveUnittest!(uint, 31));
}


@safe pure
@("registry: revive (ulong)")
unittest
{
	mixin(registryReviveUnittest!(ulong, 63));
}


private template registrySpawnUnittest(T, T amount)
{
	enum registrySpawnUnittest = q{
		auto registry = new BasicRegistry!(}~T.stringof~","~amount.stringof~q{);
		registry.create;
		auto exception = expectThrows!MaximumEntitiesReachedException(registry.spawn);
		assertEquals("Maximum entities reached!", exception.msg);
	};
}


@safe pure
@("registry: spawn (ubyte)")
unittest
{
	mixin (registrySpawnUnittest!(ubyte, 1));
}


@safe pure
@("registry: spawn (ushort)")
unittest
{
	mixin (registrySpawnUnittest!(ushort, 1));
}


@safe pure
@("registry: spawn (uint)")
unittest
{
	mixin (registrySpawnUnittest!(uint, 1));
}


@safe pure
@("registry: spawn (ulong)")
unittest
{
	mixin (registrySpawnUnittest!(ulong, 1));
}


@safe pure
@("registry: instance types")
unittest
{
	import std.meta : AliasSeq;
	static foreach(t; AliasSeq!(ubyte, ushort, uint, ulong))
	{
		assertTrue(__traits(compiles, new BasicRegistry!(t, 1)));
		assertTrue(__traits(compiles, new BasicRegistry!(t, t.sizeof * 8 - 1)));

		assertFalse(__traits(compiles, new BasicRegistry!(t, 0)));
		assertFalse(__traits(compiles, new BasicRegistry!(t, t.sizeof * 8)));
	}

	struct Foo {}
	static foreach(t; AliasSeq!(byte, short, int, long, char, dchar, string, dstring, float, double, Foo))
	{
		assertFalse(__traits(compiles, new BasicRegistry!(t, 1)));
	}
}


@safe pure
@("registry: updateBatch")
unittest
{
	auto registry = new BasicRegistry!(ubyte, 7);

	auto e0 = registry.create;
	assertEquals(0, registry.batchOf(e0));

	// increments batch
	assertEquals(1, registry.updateBatch(e0));
	registry.discard(e0);
	auto e1 = registry.create;

	// maximum batch reached (1 bit), resets to 0!
	assertEquals(0, registry.updateBatch(e1));
}
